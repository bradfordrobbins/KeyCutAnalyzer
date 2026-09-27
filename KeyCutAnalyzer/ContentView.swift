import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import KeyCutCore

private struct OpenedImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            OpenedImage(data: data)
        }
    }
}

private struct KeyPlacement: Equatable {
    var angle: Double = 0
    var scale: CGFloat = 1
    var offset: CGSize = .zero
}

private struct FrameSampleKey: PreferenceKey {
    static var defaultValue: KeyFrameSample?
    static func reduce(value: inout KeyFrameSample?, nextValue: () -> KeyFrameSample?) {
        value = nextValue() ?? value
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var placement = KeyPlacement()
    @State private var frameSample: KeyFrameSample?
    @State private var bladeOffset = CGSize(width: 72, height: 0)
    @State private var bladeMoved = false
    @State private var markerOffsets: [CGSize] = []
    @State private var manual: ManualBladeReading?
    @State private var showPhotoLibrary = false
    @State private var showFileImporter = false
    @State private var pickedPhoto: PhotosPickerItem?

    var body: some View {
        ZStack {
            cameraStage
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) { topControls }
        .overlay(alignment: .bottom) { bottomControls }
        .background(Theme.camera)
        .preferredColorScheme(.dark)
        .task { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                camera.start()
            }
        }
        .onChange(of: camera.capturedImage == nil) { _, isEmpty in
            resetGuides()
            if !isEmpty {
                placement = KeyPlacement()
            }
        }
        .onChange(of: placement) { _, _ in
            manual = nil
        }
        .onPreferenceChange(FrameSampleKey.self) { frameSample = $0 }
        .photosPicker(isPresented: $showPhotoLibrary, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let opened = try? await item.loadTransferable(type: OpenedImage.self) {
                    camera.loadPhotoData(opened.data)
                } else {
                    camera.loadPhotoData(Data())
                }
                pickedPhoto = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            camera.loadPhotoData((try? Data(contentsOf: url)) ?? Data())
        }
    }

    private var topControls: some View {
        HStack(alignment: .top, spacing: 12) {
            if camera.canSwitchCamera {
                switchCameraButton
            }
            Spacer(minLength: 12)
            ReadoutPanel(camera: camera, manual: manual)
                .frame(maxWidth: 560)
        }
        .padding(12)
    }

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(guideHint)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                if camera.capturedImage != nil {
                    Button(action: adjustMarks) {
                        Text("Adjust")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brass)
                    .disabled(!bladeMoved || markerOffsets.count < 5)
                }
                openPhotoButton
                captureButton
            }
        }
        .padding(12)
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private var cameraStage: some View {
        ZStack {
                if let image = camera.capturedImage {
                    MeasuredPhoto(
                        image: image,
                        imageSize: camera.imageSize,
                        placement: $placement,
                        gesturesEnabled: true,
                        bladeOffset: bladeOffset,
                        markerOffsets: markerOffsets,
                        spec: camera.spec,
                        onBladeDrag: noteBladeDrag,
                        onMarkerDrag: noteMarkerDrag
                    )
                } else {
                    CameraPreview(
                    previewEpoch: camera.previewEpoch,
                    reading: nil,
                    imageSize: camera.imageSize,
                    onPreviewReady: { camera.attachPreview($0) },
                    onTapNormalized: { camera.isolate(atNormalizedTopLeft: $0) },
                    onDoubleTap: { camera.clearIsolation() }
                )
            }

            if camera.capturedImage == nil, let error = camera.cameraError {
                VStack(spacing: 12) {
                    Text(error)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    if camera.needsCameraEnable {
                        Button("Enable Camera") {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brass)
                    }
                }
                .padding(16)
                .background(Theme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                .padding(20)
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.camera)
    }

    private var switchCameraButton: some View {
        Button(action: camera.switchCamera) {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.title3.weight(.semibold))
                .padding(10)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .accessibilityLabel("Switch camera")
    }

    private var openPhotoButton: some View {
        Menu {
            Button("Photo Library") { showPhotoLibrary = true }
            Button("Choose File") { showFileImporter = true }
        } label: {
            Text("Open Photo")
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.brass)
        .disabled(camera.isMeasuring)
        .accessibilityLabel("Open photo")
    }

    private var captureButton: some View {
        let hasPhoto = camera.capturedImage != nil
        return Button(action: hasPhoto ? camera.recapture : camera.measure) {
            Text(hasPhoto ? "Recapture" : "Capture")
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.brass)
        .disabled(camera.isMeasuring || (camera.cameraError != nil && !hasPhoto))
        .accessibilityLabel(hasPhoto ? "Recapture" : "Capture")
    }

    private var guideHint: String {
        guard camera.capturedImage != nil else { return camera.isolationHint }
        if manual != nil {
            return "Depths use 0.6248 in from marker 1 to marker 5."
        }
        if bladeMoved {
            return "Place each crosshair on a cut root. Brass lines mark 0.231 in and 0.8558 in from the shoulder."
        }
        return "Place the bottom of the shoulder on the mark. Drag the line along the bottom of the blade."
    }

    private func resetGuides() {
        bladeOffset = CGSize(width: 72, height: 0)
        bladeMoved = false
        markerOffsets = []
        manual = nil
    }

    private func noteBladeDrag(_ offset: CGSize) {
        bladeOffset = offset
        manual = nil
        guard !bladeMoved else { return }
        bladeMoved = true
        markerOffsets = initialMarkers(along: offset)
    }

    private func noteMarkerDrag(_ index: Int, _ offset: CGSize) {
        guard markerOffsets.indices.contains(index) else { return }
        markerOffsets[index] = offset
        manual = nil
    }

    private func initialMarkers(along offset: CGSize) -> [CGSize] {
        let length = hypot(offset.width, offset.height)
        guard length > 1 else { return [] }
        let unitX = offset.width / length
        let unitY = offset.height / length
        let normalX = unitY
        let normalY = -unitX
        return (0..<5).map { index in
            let distance = length * (0.22 + 0.14 * CGFloat(index))
            return CGSize(
                width: unitX * distance + normalX * 48,
                height: unitY * distance + normalY * 48
            )
        }
    }

    private func adjustMarks() {
        guard let frameSample, markerOffsets.count == 5 else { return }
        let shoulder = Point2D(frameSample.shoulderX, frameSample.shoulderY)
        let bladeEnd = Point2D(
            frameSample.shoulderX + Double(bladeOffset.width),
            frameSample.shoulderY + Double(bladeOffset.height)
        )
        let markers = markerOffsets.map {
            Point2D(frameSample.shoulderX + Double($0.width), frameSample.shoulderY + Double($0.height))
        }
        guard let reading = ManualBladeMeasure.adjust(
            shoulder: shoulder,
            bladeEnd: bladeEnd,
            markers: markers,
            spec: camera.spec
        ) else { return }
        markerOffsets = reading.cuts.map {
            CGSize(width: $0.point.x - shoulder.x, height: $0.point.y - shoulder.y)
        }
        manual = reading
    }
}

private struct MeasuredPhoto: View {
    let image: UIImage
    let imageSize: CGSize
    var placement: Binding<KeyPlacement>
    var gesturesEnabled: Bool
    var bladeOffset: CGSize
    var markerOffsets: [CGSize]
    var spec: KeySpec
    var onBladeDrag: (CGSize) -> Void
    var onMarkerDrag: (Int, CGSize) -> Void

    @State private var panOrigin: CGSize?
    @State private var pinchOrigin: CGFloat?
    @State private var rotateOrigin: Double?

    var body: some View {
        GeometryReader { geo in
            placedPhoto(in: geo.size)
        }
        .background(Theme.camera)
    }

    private func placedPhoto(in viewSize: CGSize) -> some View {
        let fit = fitScale(in: viewSize)
        let guide = keyGuide(in: viewSize)
        let current = placement.wrappedValue
        let shoulder = shoulderSpot(in: viewSize)
        let sample = KeyFrameSample(
            angle: current.angle,
            fitScale: Double(fit),
            userScale: Double(current.scale),
            offsetX: Double(current.offset.width),
            offsetY: Double(current.offset.height),
            viewWidth: Double(viewSize.width),
            viewHeight: Double(viewSize.height),
            guideX: Double(guide.minX),
            guideY: Double(guide.minY),
            guideWidth: Double(guide.width),
            guideHeight: Double(guide.height),
            shoulderX: Double(shoulder.x),
            shoulderY: Double(shoulder.y)
        )
        let shown = CGSize(
            width: displayedSize.width * fit * current.scale,
            height: displayedSize.height * fit * current.scale
        )
        let bladeEnd = CGPoint(x: shoulder.x + bladeOffset.width, y: shoulder.y + bladeOffset.height)
        let depths = ManualBladeMeasure.rootDepths(
            shoulder: Point2D(shoulder.x, shoulder.y),
            bladeEnd: Point2D(bladeEnd.x, bladeEnd.y),
            markers: markerOffsets.map { Point2D(shoulder.x + $0.width, shoulder.y + $0.height) },
            spec: spec
        )
        return ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: shown.width, height: shown.height)
                .rotationEffect(.radians(current.angle))
                .position(
                    x: viewSize.width / 2 + current.offset.width,
                    y: viewSize.height / 2 + current.offset.height
                )
            bladeGuide(shoulder: shoulder, end: bladeEnd)
            stationGuides(shoulder: shoulder, end: bladeEnd)
            ForEach(Array(markerOffsets.enumerated()), id: \.offset) { index, offset in
                bitMarker(
                    index: index,
                    at: CGPoint(x: shoulder.x + offset.width, y: shoulder.y + offset.height),
                    shoulder: shoulder,
                    depth: depths?.indices.contains(index) == true ? depths?[index] : nil
                )
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .contentShape(Rectangle())
        .modifier(PlacementGestures(
            enabled: gesturesEnabled,
            placement: placement,
            panOrigin: $panOrigin,
            pinchOrigin: $pinchOrigin,
            rotateOrigin: $rotateOrigin
        ))
        .preference(key: FrameSampleKey.self, value: sample)
        .coordinateSpace(name: "photo")
        .clipped()
    }

    /// Fixed mark. The photo moves under it; the blade should run to the right.
    private func shoulderSpot(in viewSize: CGSize) -> CGPoint {
        CGPoint(x: viewSize.width * 0.28, y: viewSize.height * 0.58)
    }

    private func bladeGuide(shoulder: CGPoint, end: CGPoint) -> some View {
        ZStack {
            Canvas { context, _ in
                var path = Path()
                let arm: CGFloat = 16
                path.move(to: CGPoint(x: shoulder.x - arm, y: shoulder.y))
                path.addLine(to: CGPoint(x: shoulder.x + arm, y: shoulder.y))
                path.move(to: CGPoint(x: shoulder.x, y: shoulder.y - arm))
                path.addLine(to: CGPoint(x: shoulder.x, y: shoulder.y + arm))
                path.move(to: shoulder)
                path.addLine(to: end)
                context.stroke(path, with: .color(Theme.measure), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .allowsHitTesting(false)
            Text("Shoulder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.measure)
                .position(x: shoulder.x, y: shoulder.y - 28)
                .allowsHitTesting(false)
            Circle()
                .fill(Theme.measure)
                .frame(width: 18, height: 18)
                .position(end)
                .highPriorityGesture(drag { location in
                    onBladeDrag(CGSize(width: location.x - shoulder.x, height: location.y - shoulder.y))
                })
        }
    }

    private func stationGuides(shoulder: CGPoint, end: CGPoint) -> some View {
        let marks = ManualBladeMeasure.stationMarks(
            shoulder: Point2D(shoulder.x, shoulder.y),
            bladeEnd: Point2D(end.x, end.y),
            markers: markerOffsets.map { Point2D(shoulder.x + $0.width, shoulder.y + $0.height) },
            spec: spec
        )
        return ZStack {
            Canvas { context, _ in
                guard let marks else { return }
                for station in marks.stations {
                    strokeStation(station, up: marks.up, in: &context)
                }
            }
            .allowsHitTesting(false)
            if let marks {
                ForEach(Array(marks.stations.enumerated()), id: \.offset) { index, station in
                    stationLabel("\(index + 1)", at: station, up: marks.up)
                }
            }
        }
    }

    private func strokeStation(_ point: Point2D, up: Point2D, in context: inout GraphicsContext) {
        let origin = CGPoint(x: point.x, y: point.y)
        var path = Path()
        path.move(to: CGPoint(x: origin.x - up.x * 36, y: origin.y - up.y * 36))
        path.addLine(to: CGPoint(x: origin.x + up.x * 288, y: origin.y + up.y * 288))
        context.stroke(
            path,
            with: .color(Theme.brass),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 4])
        )
    }

    private func stationLabel(_ title: String, at point: Point2D, up: Point2D) -> some View {
        Text(title)
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(Theme.brass)
            .position(x: point.x - up.x * 22, y: point.y - up.y * 22)
            .allowsHitTesting(false)
    }

    private func bitMarker(index: Int, at spot: CGPoint, shoulder: CGPoint, depth: Double?) -> some View {
        BitMarker(
            index: index,
            spot: spot,
            shoulder: shoulder,
            depthText: depth.map { "\(Units.formatInches($0)) in" },
            onDrag: { onMarkerDrag(index, $0) }
        )
    }

    private func drag(onChange: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("photo"))
            .onChanged { value in
                onChange(value.location)
            }
    }

    private func fitScale(in viewSize: CGSize) -> CGFloat {
        let fitted = min(viewSize.width / displayedSize.width, viewSize.height / displayedSize.height)
        return fitted.isFinite && fitted > 0 ? fitted : 1
    }

    private func keyGuide(in viewSize: CGSize) -> CGRect {
        let aspect = KeyBlanks.sc1.bowWidthInches / KeyBlanks.sc1.overallInches
        var width = viewSize.width * 0.70
        var height = width * aspect
        let maxHeight = viewSize.height * 0.70
        if height > maxHeight {
            height = maxHeight
            width = height / aspect
        }
        return CGRect(
            x: (viewSize.width - width) / 2,
            y: (viewSize.height - height) / 2,
            width: width,
            height: height
        )
    }


    private var displayedSize: CGSize {
        if imageSize.width > 1, imageSize.height > 1 {
            return imageSize
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }
}

/// The number sits above the measurement point. The crosshair center is the root used for depth.
private struct BitMarker: View {
    var index: Int
    var spot: CGPoint
    var shoulder: CGPoint
    var depthText: String?
    var onDrag: (CGSize) -> Void
    @State private var grab: CGSize?

    private let stem: CGFloat = 36

    var body: some View {
        let numberCenter = CGPoint(x: spot.x, y: spot.y - stem)
        return ZStack {
            Canvas { context, _ in
                var path = Path()
                path.move(to: CGPoint(x: spot.x, y: numberCenter.y + 14))
                path.addLine(to: spot)
                let arm: CGFloat = 10
                path.move(to: CGPoint(x: spot.x - arm, y: spot.y))
                path.addLine(to: CGPoint(x: spot.x + arm, y: spot.y))
                path.move(to: CGPoint(x: spot.x, y: spot.y - arm))
                path.addLine(to: CGPoint(x: spot.x, y: spot.y + arm))
                context.stroke(path, with: .color(Theme.measure), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .allowsHitTesting(false)
            if let depthText {
                Text(depthText)
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(Theme.ink)
                    .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                    .position(x: spot.x, y: numberCenter.y - 24)
                    .allowsHitTesting(false)
            }
            markerNumber
                .position(numberCenter)
                .highPriorityGesture(move)
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .position(spot)
                .highPriorityGesture(move)
        }
    }

    private var markerNumber: some View {
        ZStack {
            Circle()
                .stroke(Theme.measure, lineWidth: 2.5)
                .background(Circle().fill(Color.black.opacity(0.35)))
                .frame(width: 28, height: 28)
            Text("\(index + 1)")
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(Theme.measure)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("photo"))
            .onChanged { value in
                if grab == nil {
                    grab = CGSize(width: value.location.x - spot.x, height: value.location.y - spot.y)
                }
                let held = grab ?? .zero
                onDrag(CGSize(
                    width: value.location.x - shoulder.x - held.width,
                    height: value.location.y - shoulder.y - held.height
                ))
            }
            .onEnded { _ in
                grab = nil
            }
    }
}

private struct PlacementGestures: ViewModifier {
    var enabled: Bool
    var placement: Binding<KeyPlacement>
    var panOrigin: Binding<CGSize?>
    var pinchOrigin: Binding<CGFloat?>
    var rotateOrigin: Binding<Double?>

    func body(content: Content) -> some View {
        if enabled {
            content
                .gesture(pan)
                .simultaneousGesture(pinch)
                .simultaneousGesture(rotation)
        } else {
            content
        }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                if panOrigin.wrappedValue == nil {
                    panOrigin.wrappedValue = placement.wrappedValue.offset
                }
                let start = panOrigin.wrappedValue ?? .zero
                placement.wrappedValue.offset = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
            }
            .onEnded { _ in
                panOrigin.wrappedValue = nil
            }
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchOrigin.wrappedValue == nil {
                    pinchOrigin.wrappedValue = placement.wrappedValue.scale
                }
                let start = pinchOrigin.wrappedValue ?? 1
                placement.wrappedValue.scale = min(max(start * value, 0.4), 8)
            }
            .onEnded { _ in
                pinchOrigin.wrappedValue = nil
            }
    }

    private var rotation: some Gesture {
        RotationGesture()
            .onChanged { angle in
                if rotateOrigin.wrappedValue == nil {
                    rotateOrigin.wrappedValue = placement.wrappedValue.angle
                }
                let start = rotateOrigin.wrappedValue ?? 0
                placement.wrappedValue.angle = start + angle.radians
            }
            .onEnded { _ in
                rotateOrigin.wrappedValue = nil
            }
    }
}

enum Theme {
    static let camera = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.13)
    static let ink = Color(red: 0.94, green: 0.92, blue: 0.86)
    static let muted = Color(red: 0.64, green: 0.66, blue: 0.68)
    static let line = Color(red: 0.24, green: 0.26, blue: 0.28)
    static let warn = Color(red: 1.0, green: 0.78, blue: 0.70)
    static let caution = Color(red: 1.0, green: 0.88, blue: 0.40)
    static let brass = Color(red: 0.86, green: 0.73, blue: 0.42)
    static let measure = Color(red: 0.30, green: 0.90, blue: 0.45)
}
