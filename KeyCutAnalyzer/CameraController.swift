import AVFoundation
import Combine
import CoreMedia
import KeyCutCore

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var reading: KeyReading?
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var cameraError: String?
    @Published private(set) var canSwitchCamera = false
    @Published private(set) var isolationHint = "Tap the key to isolate it. Double-tap to clear."
    @Published private(set) var spec: KeySpec = KeyCatalog.sc1

    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "keycut.session")
    private let analysisQueue = DispatchQueue(label: "keycut.analysis")
    private var devices: [AVCaptureDevice] = []
    private var deviceIndex = 0
    private var videoInput: AVCaptureDeviceInput?
    private var lastAnalysis = CFAbsoluteTimeGetCurrent()
    private var busy = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private let stateLock = NSLock()
    private var seed: CGPoint?
    private var specStorage = KeyCatalog.sc1

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { [weak self] in self?.configureSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.sessionQueue.async { self.configureSession() }
                } else {
                    self.publishError("Camera access is off. Enable it so the camera can measure the key.")
                }
            }
        default:
            publishError("Camera access is off. Enable it so the camera can measure the key.")
        }
    }

    func selectSpec(id: String) {
        guard let spec = KeyCatalog.spec(id: id) else { return }
        stateLock.lock()
        specStorage = spec
        stateLock.unlock()
        self.spec = spec
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            self?.advanceCamera()
        }
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        sessionQueue.async { [weak self] in
            self?.applyRotation()
        }
    }

    /// Normalized image point, origin top-left, from the preview layer.
    func isolate(atNormalizedTopLeft point: CGPoint) {
        stateLock.lock()
        seed = point
        stateLock.unlock()
        DispatchQueue.main.async {
            self.isolationHint = "Isolating the tapped key. Double-tap to clear."
        }
    }

    func clearIsolation() {
        stateLock.lock()
        seed = nil
        stateLock.unlock()
        DispatchQueue.main.async {
            self.isolationHint = "Tap the key to isolate it. Double-tap to clear."
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high
        devices = Self.availableCameras()
        guard let device = devices.first else {
            session.commitConfiguration()
            publishError("No camera is available. The iOS Simulator has no camera. Run My Mac (Designed for iPad) or a device.")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: analysisQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
            let multiple = devices.count > 1
            DispatchQueue.main.async {
                self.canSwitchCamera = multiple
                self.cameraError = nil
            }
            applyRotation()
            session.startRunning()
        } catch {
            session.commitConfiguration()
            publishError("The camera could not start. \(error.localizedDescription)")
        }
    }

    private func advanceCamera() {
        guard devices.count > 1 else { return }
        deviceIndex = (deviceIndex + 1) % devices.count
        let device = devices[deviceIndex]
        session.beginConfiguration()
        if let videoInput {
            session.removeInput(videoInput)
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
            session.commitConfiguration()
            applyRotation()
            DispatchQueue.main.async { self.cameraError = nil }
        } catch {
            session.commitConfiguration()
            publishError("Could not switch cameras. \(error.localizedDescription)")
        }
    }

    private func applyRotation() {
        guard let device = videoInput?.device, let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(previewAngle) {
            connection.videoRotationAngle = previewAngle
        }
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(captureAngle) {
            connection.videoRotationAngle = captureAngle
        }
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
            self?.sessionQueue.async {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if let connection = self?.output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                if let preview = self?.previewLayer?.connection,
                   preview.isVideoRotationAngleSupported(coordinator.videoRotationAngleForHorizonLevelPreview) {
                    preview.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
                }
            }
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.cameraError = message
            self.reading = nil
        }
    }

    private static func availableCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]
        if #available(iOS 17.0, *) {
            types.append(.external)
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        let unique = discovery.devices.reduce(into: [AVCaptureDevice]()) { list, device in
            if !list.contains(where: { $0.uniqueID == device.uniqueID }) {
                list.append(device)
            }
        }
        return unique.sorted { lhs, rhs in
            if lhs.position == .back && rhs.position != .back { return true }
            if lhs.position != .back && rhs.position == .back { return false }
            return lhs.localizedName < rhs.localizedName
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        stateLock.lock()
        let activeSeed = seed
        stateLock.unlock()
        let interval = activeSeed == nil ? 0.10 : 0.22
        guard !busy, now - lastAnalysis >= interval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busy = true
        lastAnalysis = now
        stateLock.lock()
        let spec = specStorage
        stateLock.unlock()
        Task {
            let result = await SilhouetteExtractor.extract(
                pixelBuffer: pixelBuffer,
                spec: spec,
                normalizedTopLeftSeed: activeSeed
            )
            await MainActor.run {
                self.imageSize = result.imageSize
                self.reading = result.reading
                if let message = result.note {
                    self.isolationHint = message
                }
            }
            self.analysisQueue.async { [weak self] in
                self?.busy = false
            }
        }
    }
}
