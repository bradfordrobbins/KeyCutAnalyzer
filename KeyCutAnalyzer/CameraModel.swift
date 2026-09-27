import AVFoundation
import Combine
import Foundation
import KeyCutCore

struct CameraChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published var errorMessage: String?
    @Published var reading: KeyReading?
    @Published var devices: [CameraChoice] = []
    @Published var activeDeviceID: String?
    @Published var bufferSize: CGSize = .zero
    @Published var analysisStride: Int = 1
    @Published var selectedKeyID: String = KeyCatalog.sc1.id {
        didSet { storeSpec(id: selectedKeyID) }
    }

    private let sessionQueue = DispatchQueue(label: "keycut.session")
    private let outputQueue = DispatchQueue(label: "keycut.frames")
    private let analysisQueue = DispatchQueue(label: "keycut.analysis", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var busy = false
    private var lastAnalysis = CFAbsoluteTime(0)
    private var misses = 0
    private var didConfigure = false
    private let specLock = NSLock()
    private var specSnapshot = KeyCatalog.sc1

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureIfNeeded()
                    } else {
                        self.errorMessage = "Camera access is turned off."
                    }
                }
            }
        case .denied, .restricted:
            errorMessage = "Camera access is turned off."
        @unknown default:
            errorMessage = "Camera access is unavailable."
        }
    }

    func select(deviceID: String) {
        sessionQueue.async { [weak self] in
            self?.installCamera(id: deviceID)
        }
    }

    private func configureIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.didConfigure {
                self.didConfigure = true
                self.configureSession()
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        pinOutputToUnrotatedBuffers()

        let found = discoverDevices()
        let preferred = found.first { $0.position == .back } ?? found.first
        DispatchQueue.main.async {
            self.devices = found.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
        }
        if let preferred {
            installCamera(id: preferred.uniqueID, configuring: true)
        } else {
            DispatchQueue.main.async {
                self.errorMessage = "No camera is available."
            }
        }
        session.commitConfiguration()
    }

    private func installCamera(id: String, configuring: Bool = false) {
        let found = discoverDevices()
        guard let device = found.first(where: { $0.uniqueID == id }) else {
            DispatchQueue.main.async {
                self.errorMessage = "That camera is not available."
            }
            return
        }
        if !configuring {
            session.beginConfiguration()
        }
        defer {
            if !configuring {
                session.commitConfiguration()
            }
        }
        if let videoInput {
            session.removeInput(videoInput)
            self.videoInput = nil
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                DispatchQueue.main.async {
                    self.errorMessage = "The camera could not be started."
                }
                return
            }
            session.addInput(input)
            videoInput = input
            pinOutputToUnrotatedBuffers()
            DispatchQueue.main.async {
                self.activeDeviceID = device.uniqueID
                self.devices = found.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
                self.errorMessage = nil
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "The camera could not be started. \(error.localizedDescription)"
            }
        }
    }

    /// Leave the sample buffers in the sensor's unrotated picture so preview-layer mapping can apply video gravity.
    private func pinOutputToUnrotatedBuffers() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
    }

    private func discoverDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .continuityCamera,
            .external,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        var seen = Set<String>()
        return discovery.devices.filter { seen.insert($0.uniqueID).inserted }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard !busy, now - lastAnalysis >= 0.10 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let frame = FrameSegmenter.copiedFrame(from: pixelBuffer) else { return }
        lastAnalysis = now
        busy = true
        specLock.lock()
        let spec = specSnapshot
        specLock.unlock()
        analysisQueue.async { [weak self] in
            let reading = FrameSegmenter.reading(gray: frame.gray, width: frame.width, height: frame.height, spec: spec)
            let result = reading.map { (reading: $0, frame: frame) }
            DispatchQueue.main.async {
                self?.publish(result)
            }
            self?.outputQueue.async {
                self?.busy = false
            }
        }
    }

    private func publish(_ result: (reading: KeyReading, frame: AnalysisFrame)?) {
        if let result {
            misses = 0
            reading = result.reading
            bufferSize = CGSize(width: result.frame.bufferWidth, height: result.frame.bufferHeight)
            analysisStride = result.frame.stride
        } else {
            misses += 1
            if misses >= 6 {
                reading = nil
            }
        }
    }

    private func storeSpec(id: String) {
        let spec = KeyCatalog.spec(id: id) ?? KeyCatalog.sc1
        specLock.lock()
        specSnapshot = spec
        specLock.unlock()
    }
}
