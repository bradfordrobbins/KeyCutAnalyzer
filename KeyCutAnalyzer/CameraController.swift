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
    /// Increments after the capture session is running so the preview layer can reattach.
    @Published private(set) var previewEpoch = 0
    /// True when iOS will not show the camera until the user turns it on for this app.
    @Published private(set) var needsCameraEnable = false

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
            DispatchQueue.main.async { self.needsCameraEnable = false }
            sessionQueue.async { [weak self] in self?.configureSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    DispatchQueue.main.async { self.needsCameraEnable = false }
                    self.sessionQueue.async { self.configureSession() }
                } else {
                    self.denyCamera()
                }
            }
        case .denied, .restricted:
            denyCamera()
        @unknown default:
            denyCamera()
        }
    }

    private func denyCamera() {
        DispatchQueue.main.async { self.needsCameraEnable = true }
        publishError("Camera access is off. Enable it so the camera can measure the key.")
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
        if session.isRunning {
            publishRunning()
            return
        }
        if videoInput != nil {
            session.startRunning()
            publishRunning()
            return
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        devices = Self.availableCameras()
        guard let device = devices.first else {
            session.commitConfiguration()
            publishError("No camera is available. On iPhone, confirm Developer Mode is on and that Settings allows KeyCutAnalyzer to use the camera. The iOS Simulator has no camera.")
            return
        }
        do {
            try configure(device)
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                publishError("The camera could not be opened.")
                return
            }
            session.addInput(input)
            videoInput = input
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: analysisQueue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                publishError("The camera could not be opened.")
                return
            }
            session.addOutput(output)
            session.commitConfiguration()
            applyRotation()
            session.startRunning()
            publishRunning()
        } catch {
            session.commitConfiguration()
            publishError("The camera could not start. \(error.localizedDescription)")
        }
    }

    private func configure(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    private func publishRunning() {
        let multiple = devices.count > 1
        DispatchQueue.main.async {
            self.canSwitchCamera = multiple
            self.cameraError = nil
            self.needsCameraEnable = false
            self.previewEpoch += 1
            self.applyRotation()
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
            let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            self?.sessionQueue.async {
                if let connection = self?.output.connection(with: .video), connection.isVideoRotationAngleSupported(captureAngle) {
                    connection.videoRotationAngle = captureAngle
                }
            }
            DispatchQueue.main.async {
                if let connection = self?.previewLayer?.connection, connection.isVideoRotationAngleSupported(previewAngle) {
                    connection.videoRotationAngle = previewAngle
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
        var unique = discovery.devices.reduce(into: [AVCaptureDevice]()) { list, device in
            if !list.contains(where: { $0.uniqueID == device.uniqueID }) {
                list.append(device)
            }
        }
        if let rear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           !unique.contains(where: { $0.uniqueID == rear.uniqueID }) {
            unique.insert(rear, at: 0)
        }
        return unique.sorted { lhs, rhs in
            let lhsRank = cameraRank(lhs)
            let rhsRank = cameraRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.localizedName < rhs.localizedName
        }
    }

    /// Rear wide camera first, so an iPhone opens the lens used to photograph the key.
    private static func cameraRank(_ device: AVCaptureDevice) -> Int {
        if device.deviceType == .builtInWideAngleCamera && device.position == .back { return 0 }
        if device.position == .back { return 1 }
        if device.deviceType == .builtInWideAngleCamera { return 2 }
        return 3
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
