import AVFoundation
import Combine
import CoreMedia
import KeyCutCore
import UIKit

/// How the user turned and placed the photo inside the on-screen key frame.
struct KeyFrameSample: Equatable {
    var angle: Double = 0
    var fitScale: Double = 1
    var userScale: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0
    var viewWidth: Double = 0
    var viewHeight: Double = 0
    var guideX: Double = 0
    var guideY: Double = 0
    var guideWidth: Double = 0
    var guideHeight: Double = 0
    /// Shoulder mark in the view, in points. The blade extends to the right of this spot.
    var shoulderX: Double = 0
    var shoulderY: Double = 0
}

enum KeyCutLog {
    static func event(_ message: String) {
        print("[KeyCut] \(message)")
    }

    static func elapsed(_ label: String, since start: CFAbsoluteTime) {
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "[KeyCut] %@ %.0f ms", label, milliseconds))
    }
}

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var reading: KeyReading?
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var cameraError: String?
    @Published private(set) var canSwitchCamera = false
    @Published private(set) var isolationHint = "Hold the phone in landscape. Key in profile, then tap Capture."
    @Published private(set) var isMeasuring = false
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var maskImage: CGImage?
    @Published private(set) var scan: BladeScan?
    @Published private(set) var scanStep = 0
    /// Horizontal edge pixels from the last bottom search, in image pixels.
    @Published private(set) var foundEdges: [Point2D] = []
    /// Edge pixels that lie on the line chosen as the blade bottom.
    @Published private(set) var selectedEdges: [Point2D] = []
    @Published private(set) var spec: KeySpec = KeyCatalog.sc1
    /// Increments after the capture session is running so the preview layer can reattach.
    @Published private(set) var previewEpoch = 0
    /// True when iOS will not show the camera until the user turns it on for this app.
    @Published private(set) var needsCameraEnable = false

    private let output = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "keycut.session", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "keycut.analysis", qos: .userInitiated)
    private var devices: [AVCaptureDevice] = []
    private var deviceIndex = 0
    private var videoInput: AVCaptureDeviceInput?
    private var lastAnalysis = CFAbsoluteTimeGetCurrent()
    private var stableKeyFrames = 0
    private var previewCheckRunning = false
    private var measuring = false
    private var autoCaptureArmed = true
    private var captureStarted: CFAbsoluteTime = 0
    private var stillBuffer: CVPixelBuffer?
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
        let buffer = stillBuffer
        let busy = measuring
        if buffer != nil, !busy {
            measuring = true
        }
        stateLock.unlock()
        self.spec = spec
        guard let buffer, !busy else { return }
        publishMeasuring("Measuring the captured photo.")
        analyze(buffer)
    }

    func measure() {
        KeyCutLog.event("Measure tapped")
        sessionQueue.async { [weak self] in
            self?.beginStillCapture()
        }
    }

    /// Finds the blade from the shoulder mark. The photo stays where the user placed it.
    func measureFramed(_ sample: KeyFrameSample) {
        stateLock.lock()
        let buffer = stillBuffer
        let spec = specStorage
        let busy = measuring
        if buffer != nil, !busy {
            measuring = true
        }
        stateLock.unlock()
        guard let buffer, !busy else { return }
        publishMeasuring("Finding the blade.")
        let target = AnalysisTarget(self)
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        let shoulder = Self.imagePoint(
            fromViewX: sample.shoulderX,
            viewY: sample.shoulderY,
            sample: sample,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        KeyCutLog.event("blade scan shoulder \(Int(shoulder.x.rounded())),\(Int(shoulder.y.rounded()))")
        Task {
            let boundary = await SilhouetteExtractor.boundary(of: buffer)
            let lifted = await BottomEdgeDetector.lift(in: buffer, shoulder: shoulder)
            let search = BladeBottomFinder.choose(polylines: lifted.chains, shoulder: shoulder)
            let attempt: BladeScanAttempt
            if let points = boundary {
                attempt = BladeScanner.scan(
                    boundary: points,
                    shoulder: shoulder,
                    spec: spec,
                    search: search
                )
            } else {
                attempt = BladeScanAttempt(scan: nil, foundEdges: search.edges, selectedEdges: search.selected)
            }
            DispatchQueue.main.async {
                target.controller?.applyScan(
                    attempt,
                    mask: lifted.mask,
                    size: CGSize(width: sourceWidth, height: sourceHeight)
                )
            }
        }
    }

    func stepScan(by delta: Int) {
        guard let scan else { return }
        let step = min(max(scanStep + delta, 0), BladeScan.stepCount - 1)
        scanStep = step
        isolationHint = hint(for: scan, step: step)
    }

    private func abandonFrame(_ message: String) {
        stateLock.lock()
        measuring = false
        stateLock.unlock()
        isMeasuring = false
        isolationHint = message
    }

    /// Uses an existing still instead of the camera. The align-and-measure path is the same as a capture.
    func loadPhotoData(_ data: Data) {
        DispatchQueue.main.async {
            guard let image = UIImage(data: data) else {
                self.isolationHint = "That photo could not be read."
                KeyCutLog.event("opened photo unreadable")
                return
            }
            self.installOpenedPhoto(image)
        }
    }

    func recapture() {
        stateLock.lock()
        seed = nil
        stillBuffer = nil
        measuring = false
        autoCaptureArmed = true
        stableKeyFrames = 0
        stateLock.unlock()
        reading = nil
        scan = nil
        scanStep = 0
        foundEdges = []
        selectedEdges = []
        capturedImage = nil
        maskImage = nil
        imageSize = .zero
        isMeasuring = false
        isolationHint = "Hold the phone in landscape. Key in profile, then tap Capture."
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            self?.advanceCamera()
        }
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        sessionQueue.async { [weak self] in
            guard let self else { return }
            layer.session = self.session
            self.applyRotation()
        }
    }

    /// Normalized image point, origin top-left, from the preview layer.
    func isolate(atNormalizedTopLeft point: CGPoint) {
        stateLock.lock()
        seed = point
        stateLock.unlock()
        isolationHint = "Key marked. Tap Measure, or hold steady."
    }

    func clearIsolation() {
        stateLock.lock()
        seed = nil
        stateLock.unlock()
        isolationHint = "Hold the phone in landscape. Key in profile, then tap Capture."
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
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
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
            photoOutput.maxPhotoQualityPrioritization = .quality
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                applyPhotoDimensions()
            }
            session.commitConfiguration()
            applyRotation()
            let sessionStart = CFAbsoluteTimeGetCurrent()
            KeyCutLog.event("session.startRunning")
            session.startRunning()
            KeyCutLog.elapsed("session.startRunning", since: sessionStart)
            publishRunning()
        } catch {
            session.commitConfiguration()
            publishError("The camera could not start. \(error.localizedDescription)")
        }
    }

    private func configure(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if let format = Self.fullFieldFormat(for: device) {
            device.activeFormat = format
            let zoom = min(max(1, device.minAvailableVideoZoomFactor), device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = zoom
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            KeyCutLog.event("full field \(dimensions.width)x\(dimensions.height) fov \(String(format: "%.1f", format.videoFieldOfView))°")
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    /// Widest field of view that still supports a full-resolution still, with a preview size the live check can keep up with.
    private static func fullFieldFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = device.formats
        guard let widest = formats.map(\.videoFieldOfView).max() else { return nil }
        let wide = formats.filter { $0.videoFieldOfView >= widest - 0.75 }
        func photoArea(_ format: AVCaptureDevice.Format) -> Int {
            format.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
        }
        func videoArea(_ format: AVCaptureDevice.Format) -> Int {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dimensions.width) * Int(dimensions.height)
        }
        guard let bestPhoto = wide.map(photoArea).max(), bestPhoto > 0 else {
            return wide.max { videoArea($0) < videoArea($1) }
        }
        let photoCapable = wide.filter { photoArea($0) == bestPhoto }
        let practical = photoCapable.filter { format in
            let area = videoArea(format)
            return area >= 1280 * 720 && area <= 1920 * 1440
        }
        let pool = practical.isEmpty ? photoCapable : practical
        return pool.min { videoArea($0) < videoArea($1) }
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
            try configure(device)
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
            applyPhotoDimensions()
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
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(captureAngle) {
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

private final class AnalysisTarget: @unchecked Sendable {
    weak var controller: CameraController?

    init(_ controller: CameraController) {
        self.controller = controller
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        stateLock.lock()
        let armed = autoCaptureArmed
        let busy = measuring
        let spec = specStorage
        stateLock.unlock()
        guard armed, !busy, now - lastAnalysis >= 0.25 else { return }
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        stateLock.lock()
        let alreadyChecking = previewCheckRunning
        if !alreadyChecking {
            previewCheckRunning = true
        }
        stateLock.unlock()
        guard !alreadyChecking else { return }
        lastAnalysis = now
        let retained = sampleBuffer
        let checkStart = CFAbsoluteTimeGetCurrent()
        let target = AnalysisTarget(self)
        let queue = analysisQueue
        Task {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(retained) else {
                queue.async {
                    target.controller?.finishPreviewCheck(found: false, width: 0, height: 0, started: checkStart)
                }
                return
            }
            let found = await SilhouetteExtractor.containsKey(pixelBuffer: pixelBuffer, spec: spec)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            queue.async {
                target.controller?.finishPreviewCheck(found: found, width: width, height: height, started: checkStart)
            }
        }
    }

    private func finishPreviewCheck(found: Bool, width: Int, height: Int, started: CFAbsoluteTime) {
        stateLock.lock()
        previewCheckRunning = false
        let stillWaiting = autoCaptureArmed && !measuring
        stateLock.unlock()
        KeyCutLog.elapsed("preview key check \(width)x\(height) found=\(found)", since: started)
        guard stillWaiting else {
            KeyCutLog.event("preview key check dropped, capture already in progress")
            return
        }
        if found {
            stableKeyFrames += 1
            let count = stableKeyFrames
            DispatchQueue.main.async {
                guard self.capturedImage == nil, !self.isMeasuring else { return }
                self.isolationHint = count >= 3 ? "Key held still. Capturing a photo." : "Key in frame. Hold steady."
            }
            if count >= 3 {
                KeyCutLog.event("auto capture after \(count) stable preview fits")
                sessionQueue.async { [weak self] in
                    self?.beginStillCapture()
                }
            }
        } else if stableKeyFrames != 0 {
            stableKeyFrames = 0
            DispatchQueue.main.async {
                guard self.capturedImage == nil, !self.isMeasuring else { return }
                self.isolationHint = "Hold the phone in landscape. Key in profile, then tap Capture."
            }
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if captureStarted > 0 {
            KeyCutLog.elapsed("photo processing", since: captureStarted)
        }
        if let error {
            finishCapture(message: "The photo could not be taken. \(error.localizedDescription)")
            return
        }
        let convertStart = CFAbsoluteTimeGetCurrent()
        guard let image = uprightImage(from: photo), let buffer = pixelBuffer(from: image.cgImage) else {
            KeyCutLog.event("photo convert failed")
            finishCapture(message: "The photo could not be read.")
            return
        }
        KeyCutLog.elapsed("photo convert \(Int(image.size.width))x\(Int(image.size.height))", since: convertStart)
        let display = image
        stateLock.lock()
        stillBuffer = buffer
        measuring = false
        stateLock.unlock()
        DispatchQueue.main.async {
            self.reading = nil
            self.scan = nil
            self.scanStep = 0
            self.foundEdges = []
            self.selectedEdges = []
            self.maskImage = nil
            self.imageSize = display.size
            self.capturedImage = display
            self.isMeasuring = false
            self.isolationHint = Self.shoulderHint
            KeyCutLog.event("photo on screen \(Int(display.size.width))x\(Int(display.size.height))")
        }
    }

    private func beginStillCapture() {
        stateLock.lock()
        let already = measuring
        if !already {
            measuring = true
            autoCaptureArmed = false
        }
        stateLock.unlock()
        guard !already else { return }
        DispatchQueue.main.async {
            self.reading = nil
            self.maskImage = nil
            self.isolationHint = "Capturing a sharp photo."
            self.isMeasuring = true
        }
        guard session.isRunning else {
            finishCapture(message: "The camera is not ready.")
            return
        }
        let settings = AVCapturePhotoSettings()
        let dimensions = photoOutput.maxPhotoDimensions
        if dimensions.width > 0, dimensions.height > 0 {
            settings.maxPhotoDimensions = dimensions
        }
        settings.photoQualityPrioritization = .quality
        KeyCutLog.event("capturePhoto \(dimensions.width)x\(dimensions.height) quality=quality")
        captureStarted = CFAbsoluteTimeGetCurrent()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func analyze(_ buffer: CVPixelBuffer, origin: CGPoint = .zero) {
        stateLock.lock()
        let spec = specStorage
        stateLock.unlock()
        let target = AnalysisTarget(self)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        KeyCutLog.event("still analysis start \(width)x\(height) seed=false")
        let analysisStart = CFAbsoluteTimeGetCurrent()
        let shift = Point2D(Double(origin.x), Double(origin.y))
        let displayedSize = imageSize
        Task {
            let result = await SilhouetteExtractor.extract(
                pixelBuffer: buffer,
                spec: spec,
                normalizedTopLeftSeed: nil,
                detail: .still
            )
            let reading = result.reading?.translated(by: shift)
            let note = result.note
            KeyCutLog.elapsed("still analysis reading=\(reading != nil)", since: analysisStart)
            DispatchQueue.main.async {
                target.controller?.applyAnalysis(reading: reading, size: displayedSize, note: note, maskImage: nil, displayOnSuccess: nil)
            }
        }
    }

    private func applyAnalysis(
        reading: KeyReading?,
        size: CGSize,
        note: String?,
        maskImage: CGImage?,
        displayOnSuccess: UIImage? = nil
    ) {
        stateLock.lock()
        measuring = false
        stateLock.unlock()
        self.maskImage = maskImage
        isMeasuring = false
        let accepted = reading.flatMap { marksAreOnImage($0, image: size) ? $0 : nil }
        if accepted != nil, let displayOnSuccess {
            capturedImage = displayOnSuccess
            imageSize = displayOnSuccess.size
        } else if size.width > 1, size.height > 1, displayOnSuccess == nil {
            imageSize = size
        }
        self.reading = accepted
        if let accepted {
            let marks = accepted.overlay.cuts.flatMap { [$0.bottom, $0.root] }
            KeyCutLog.event("reading code=\(accepted.code) cuts=\(accepted.cuts.count) marks x=\(pixel(marks.map(\.x).min()))...\(pixel(marks.map(\.x).max())) y=\(pixel(marks.map(\.y).min()))...\(pixel(marks.map(\.y).max())) image=\(pixel(size.width))x\(pixel(size.height))")
        } else if reading != nil {
            KeyCutLog.event("reading discarded, marks off the photo")
        } else {
            KeyCutLog.event("reading code=nil cuts=0")
        }
        if let note {
            isolationHint = note
        } else if accepted == nil {
            isolationHint = Self.shoulderHint
        } else {
            isolationHint = "Analysis held."
        }
    }

    private func marksAreOnImage(_ reading: KeyReading, image: CGSize) -> Bool {
        let width = Double(image.width)
        let height = Double(image.height)
        guard width > 1, height > 1 else { return false }
        let points = reading.overlay.cuts.flatMap { [$0.bottom, $0.root, $0.widthStart, $0.widthEnd] }
        guard !points.isEmpty else { return false }
        let inside = points.filter {
            $0.x.isFinite && $0.y.isFinite && $0.x >= -width * 0.02 && $0.x <= width * 1.02 && $0.y >= -height * 0.02 && $0.y <= height * 1.02
        }
        return inside.count >= points.count / 2
    }

    private func pixel(_ value: Double?) -> String {
        guard let value, value.isFinite, abs(value) < 1_000_000_000 else { return "off" }
        return String(Int(value.rounded()))
    }

    private func publishMeasuring(_ message: String) {
        DispatchQueue.main.async {
            self.isMeasuring = true
            self.scan = nil
            self.scanStep = 0
            self.foundEdges = []
            self.selectedEdges = []
            self.maskImage = nil
            self.isolationHint = message
        }
    }

    private func finishCapture(message: String) {
        stateLock.lock()
        measuring = false
        autoCaptureArmed = true
        stableKeyFrames = 0
        stateLock.unlock()
        DispatchQueue.main.async {
            self.isMeasuring = false
            self.isolationHint = message
        }
    }

    private func applyPhotoDimensions() {
        guard let device = videoInput?.device else { return }
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        guard let largest = supported.max(by: { lhs, rhs in
            Int(lhs.width) * Int(lhs.height) < Int(rhs.width) * Int(rhs.height)
        }) else { return }
        photoOutput.maxPhotoDimensions = largest
    }

    private static let shoulderHint = "Place the bottom of the shoulder on the mark. Head on the left, blade to the right, bites up."

    private func applyScan(_ attempt: BladeScanAttempt, mask: CGImage?, size: CGSize) {
        stateLock.lock()
        measuring = false
        stateLock.unlock()
        isMeasuring = false
        reading = nil
        scan = attempt.scan
        scanStep = 0
        foundEdges = attempt.foundEdges
        selectedEdges = attempt.selectedEdges
        maskImage = mask
        if size.width > 1, size.height > 1 {
            imageSize = size
        }
        if let scan = attempt.scan {
            isolationHint = hint(for: scan, step: 0)
            KeyCutLog.event("blade scan code=\(scan.code) level \(String(format: "%+.1f", scan.levelingDegrees))° edges \(attempt.foundEdges.count) selected \(attempt.selectedEdges.count)")
        } else if mask != nil {
            isolationHint = "Step 1. The key at the shoulder mark, lifted from the background. No bottom line matched."
            KeyCutLog.event("blade scan failed with a key mask")
        } else if !attempt.foundEdges.isEmpty {
            isolationHint = "No key at the shoulder mark. \(attempt.foundEdges.count) edges are shown."
            KeyCutLog.event("blade scan failed edges \(attempt.foundEdges.count)")
        } else {
            isolationHint = Self.shoulderHint
            KeyCutLog.event("blade scan failed")
        }
    }

    private func hint(for scan: BladeScan, step: Int) -> String {
        if step == 0 {
            return maskImage == nil
                ? "Step 1. No key was found at the shoulder mark."
                : scan.caption(for: 0)
        }
        guard step == 1 else { return scan.caption(for: step) }
        return scan.caption(for: 1) + " \(foundEdges.count) edges found, \(selectedEdges.count) on the chosen line."
    }

    /// Maps a view point through the user's pan, zoom, and rotation onto the original photo.
    private static func imagePoint(
        fromViewX viewX: Double,
        viewY: Double,
        sample: KeyFrameSample,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> Point2D {
        let span = sample.fitScale * sample.userScale
        let relativeX = (viewX - sample.viewWidth / 2 - sample.offsetX) / span
        let relativeY = (viewY - sample.viewHeight / 2 - sample.offsetY) / span
        let cosine = cos(sample.angle)
        let sine = sin(sample.angle)
        return Point2D(
            cosine * relativeX + sine * relativeY + Double(sourceWidth) / 2,
            -sine * relativeX + cosine * relativeY + Double(sourceHeight) / 2
        )
    }

    /// Maps a pixel in the framed crop back onto the original photo.
    private static func imagePoint(
        fromCrop crop: Point2D,
        sample: KeyFrameSample,
        cropWidth: Int,
        cropHeight: Int,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> Point2D {
        let span = sample.fitScale * sample.userScale
        let viewX = sample.guideX + crop.x / Double(cropWidth) * sample.guideWidth
        let viewY = sample.guideY + crop.y / Double(cropHeight) * sample.guideHeight
        let relativeX = (viewX - sample.viewWidth / 2 - sample.offsetX) / span
        let relativeY = (viewY - sample.viewHeight / 2 - sample.offsetY) / span
        let cosine = cos(sample.angle)
        let sine = sin(sample.angle)
        return Point2D(
            cosine * relativeX + sine * relativeY + Double(sourceWidth) / 2,
            -sine * relativeX + cosine * relativeY + Double(sourceHeight) / 2
        )
    }

    /// Samples the guide rectangle after the user's pan, zoom, and rotation. Positive angle matches SwiftUI's clockwise rotation.
    private static func frameBuffer(_ source: CVPixelBuffer, sample: KeyFrameSample) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let span = sample.fitScale * sample.userScale
        guard sourceWidth > 2, sourceHeight > 2, span > 0.0001, sample.guideWidth > 8, sample.guideHeight > 8 else { return nil }
        var width = Int((sample.guideWidth / span).rounded())
        var height = Int((sample.guideHeight / span).rounded())
        let longest = max(width, height)
        if longest > 2400 {
            let shrink = 2400.0 / Double(longest)
            width = max(64, Int((Double(width) * shrink).rounded()))
            height = max(64, Int((Double(height) * shrink).rounded()))
        }
        guard width >= 64, height >= 64 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destBase = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destStride = CVPixelBufferGetBytesPerRow(buffer)
        let sourceBytes = sourceBase.assumingMemoryBound(to: UInt8.self)
        let destBytes = destBase.assumingMemoryBound(to: UInt8.self)
        let cosine = cos(sample.angle)
        let sine = sin(sample.angle)
        let centerX = Double(sourceWidth) / 2
        let centerY = Double(sourceHeight) / 2
        for row in 0..<height {
            let destRow = destBytes.advanced(by: row * destStride)
            let viewY = sample.guideY + (Double(row) + 0.5) / Double(height) * sample.guideHeight
            let relativeY = (viewY - sample.viewHeight / 2 - sample.offsetY) / span
            for column in 0..<width {
                let viewX = sample.guideX + (Double(column) + 0.5) / Double(width) * sample.guideWidth
                let relativeX = (viewX - sample.viewWidth / 2 - sample.offsetX) / span
                let sourceX = cosine * relativeX + sine * relativeY + centerX
                let sourceY = -sine * relativeX + cosine * relativeY + centerY
                let pixel = destRow.advanced(by: column * 4)
                samplePixel(sourceBytes, stride: sourceStride, width: sourceWidth, height: sourceHeight, x: sourceX, y: sourceY, into: pixel)
            }
        }
        KeyCutLog.event("framed image \(width)x\(height)")
        return buffer
    }

    private static func samplePixel(
        _ source: UnsafePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int,
        x: Double,
        y: Double,
        into pixel: UnsafeMutablePointer<UInt8>
    ) {
        let clampedX = min(max(x, 0), Double(width - 1))
        let clampedY = min(max(y, 0), Double(height - 1))
        let x0 = Int(clampedX)
        let y0 = Int(clampedY)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let xWeight = clampedX - Double(x0)
        let yWeight = clampedY - Double(y0)
        for channel in 0..<4 {
            let topLeft = Double(source[y0 * stride + x0 * 4 + channel])
            let topRight = Double(source[y0 * stride + x1 * 4 + channel])
            let bottomLeft = Double(source[y1 * stride + x0 * 4 + channel])
            let bottomRight = Double(source[y1 * stride + x1 * 4 + channel])
            let top = topLeft + (topRight - topLeft) * xWeight
            let bottom = bottomLeft + (bottomRight - bottomLeft) * xWeight
            pixel[channel] = UInt8(min(max(top + (bottom - top) * yWeight, 0), 255).rounded())
        }
    }

    private static func image(from buffer: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: base, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: bitmap),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private func installOpenedPhoto(_ image: UIImage) {
        guard let display = displayImage(from: image), let buffer = pixelBuffer(from: display.cgImage) else {
            isolationHint = "That photo could not be read."
            KeyCutLog.event("opened photo unreadable")
            return
        }
        stateLock.lock()
        seed = nil
        stillBuffer = buffer
        measuring = false
        autoCaptureArmed = false
        stableKeyFrames = 0
        stateLock.unlock()
        reading = nil
        scan = nil
        scanStep = 0
        foundEdges = []
        selectedEdges = []
        maskImage = nil
        imageSize = display.size
        capturedImage = display
        isMeasuring = false
        isolationHint = Self.shoulderHint
        KeyCutLog.event("opened photo \(Int(display.size.width))x\(Int(display.size.height))")
    }

    private func uprightImage(from photo: AVCapturePhoto) -> UIImage? {
        guard let cgImage = photo.cgImageRepresentation() else { return nil }
        let oriented = UIImage(cgImage: cgImage, scale: 1, orientation: uiOrientation(from: photo))
        return displayImage(from: oriented)
    }

    /// Draws the image upright and caps the long side at 3200 px, matching a camera still.
    private func displayImage(from image: UIImage) -> UIImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 2 else { return nil }
        let scale = min(1, 3200 / longest)
        let target = CGSize(
            width: (pixelWidth * scale).rounded(.toNearestOrAwayFromZero),
            height: (pixelHeight * scale).rounded(.toNearestOrAwayFromZero)
        )
        guard target.width > 2, target.height > 2 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func uiOrientation(from photo: AVCapturePhoto) -> UIImage.Orientation {
        let raw = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32 ?? 1
        switch raw {
        case 2: return .upMirrored
        case 3: return .down
        case 4: return .downMirrored
        case 5: return .leftMirrored
        case 6: return .right
        case 7: return .rightMirrored
        case 8: return .left
        default: return .up
        }
    }

    private func pixelBuffer(from image: CGImage?) -> CVPixelBuffer? {
        guard let image else { return nil }
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
