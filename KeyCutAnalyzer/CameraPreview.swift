import AVFoundation
import KeyCutCore
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let previewEpoch: Int
    let reading: KeyReading?
    let imageSize: CGSize
    let onPreviewReady: (AVCaptureVideoPreviewLayer) -> Void
    let onTapNormalized: (CGPoint) -> Void
    let onDoubleTap: () -> Void

    func makeUIView(context: Context) -> PreviewHost {
        let view = PreviewHost()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        context.coordinator.attachGestures(to: view)
        DispatchQueue.main.async {
            onPreviewReady(view.previewLayer)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewHost, context: Context) {
        context.coordinator.onTapNormalized = onTapNormalized
        context.coordinator.onDoubleTap = onDoubleTap
        if uiView.previewLayer.session !== session || context.coordinator.previewEpoch != previewEpoch {
            uiView.previewLayer.session = session
            context.coordinator.previewEpoch = previewEpoch
            onPreviewReady(uiView.previewLayer)
        }
        uiView.reading = reading
        uiView.imageSize = imageSize
        uiView.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapNormalized: onTapNormalized, onDoubleTap: onDoubleTap)
    }

    final class Coordinator: NSObject {
        var onTapNormalized: (CGPoint) -> Void
        var onDoubleTap: () -> Void
        var previewEpoch = -1

        init(onTapNormalized: @escaping (CGPoint) -> Void, onDoubleTap: @escaping () -> Void) {
            self.onTapNormalized = onTapNormalized
            self.onDoubleTap = onDoubleTap
        }

        func attachGestures(to view: PreviewHost) {
            let single = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            double.numberOfTapsRequired = 2
            single.require(toFail: double)
            view.addGestureRecognizer(single)
            view.addGestureRecognizer(double)
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PreviewHost else { return }
            let location = recognizer.location(in: view)
            let metadata = view.previewLayer.metadataOutputRectConverted(fromLayerRect: CGRect(origin: location, size: .zero))
            onTapNormalized(CGPoint(x: metadata.origin.x, y: metadata.origin.y))
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            onDoubleTap()
        }
    }
}

final class PreviewHost: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var reading: KeyReading?
    var imageSize: CGSize = .zero

    private let shape = CAShapeLayer()
    private var labels: [CATextLayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        shape.fillColor = UIColor.clear.cgColor
        shape.lineWidth = 2
        shape.strokeColor = UIColor(red: 0.86, green: 0.73, blue: 0.42, alpha: 1).cgColor
        layer.addSublayer(shape)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = bounds
        redraw()
    }

    private func redraw() {
        labels.forEach { $0.removeFromSuperlayer() }
        labels.removeAll()
        guard let reading, imageSize.width > 1, imageSize.height > 1 else {
            shape.path = nil
            return
        }
        let path = UIBezierPath()
        path.move(to: viewPoint(reading.overlay.bottomStart))
        path.addLine(to: viewPoint(reading.overlay.bottomEnd))
        path.move(to: viewPoint(reading.overlay.shoulderStart))
        path.addLine(to: viewPoint(reading.overlay.shoulderEnd))
        for (cut, geometry) in zip(reading.cuts, reading.overlay.cuts) {
            path.move(to: viewPoint(geometry.bottom))
            path.addLine(to: viewPoint(geometry.root))
            addLabel(cut: cut, at: viewPoint(geometry.label))
        }
        shape.path = path.cgPath
    }

    private func viewPoint(_ point: Point2D) -> CGPoint {
        let normalized = CGRect(
            x: point.x / imageSize.width,
            y: point.y / imageSize.height,
            width: 0,
            height: 0
        )
        return previewLayer.layerRectConverted(fromMetadataOutputRect: normalized).origin
    }

    private func addLabel(cut: CutReading, at point: CGPoint) {
        let text = CATextLayer()
        text.string = "\(cut.shoulderDistanceText)\n\(cut.rootDepthText)"
        text.fontSize = 11
        text.alignmentMode = .center
        text.foregroundColor = UIColor(red: 0.94, green: 0.92, blue: 0.86, alpha: 1).cgColor
        text.backgroundColor = UIColor(white: 0, alpha: 0.45).cgColor
        text.contentsScale = UIScreen.main.scale
        text.frame = CGRect(x: point.x - 28, y: point.y - 16, width: 56, height: 28)
        text.isWrapped = true
        layer.addSublayer(text)
        labels.append(text)
    }
}
