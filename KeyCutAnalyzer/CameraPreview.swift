import AVFoundation
import KeyCutCore
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var reading: KeyReading?
    var bufferSize: CGSize
    var analysisStride: Int

    func makeUIView(context: Context) -> KeyPreviewView {
        let view = KeyPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: KeyPreviewView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
        view.previewLayer.videoGravity = .resizeAspectFill
        view.reading = reading
        view.bufferSize = bufferSize
        view.analysisStride = max(analysisStride, 1)
        view.redrawOverlay()
    }
}

final class KeyPreviewView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let shapeLayer = CAShapeLayer()
    private var textLayers: [CATextLayer] = []
    var reading: KeyReading?
    var bufferSize: CGSize = .zero
    var analysisStride: Int = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.strokeColor = UIColor(red: 0.91, green: 0.76, blue: 0.42, alpha: 0.95).cgColor
        shapeLayer.lineWidth = 1.5
        shapeLayer.lineCap = .round
        layer.addSublayer(shapeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        redrawOverlay()
    }

    func redrawOverlay() {
        textLayers.forEach { $0.removeFromSuperlayer() }
        textLayers.removeAll()
        guard let reading, bufferSize.width > 1, bufferSize.height > 1, bounds.width > 1 else {
            shapeLayer.path = nil
            return
        }

        let path = UIBezierPath()
        if let first = reading.cuts.first, let last = reading.cuts.last {
            path.move(to: viewPoint(first.bottomPoint))
            path.addLine(to: viewPoint(last.bottomPoint))
        }
        for cut in reading.cuts {
            let bottom = viewPoint(cut.bottomPoint)
            let root = viewPoint(cut.rootPoint)
            path.move(to: bottom)
            path.addLine(to: root)
            let label = makeLabel(shoulder: cut.shoulderText, root: cut.rootText)
            let dx = root.x - bottom.x
            let dy = root.y - bottom.y
            let length = max(hypot(dx, dy), 1)
            let origin = CGPoint(x: root.x + dx / length * 10 - 22, y: root.y + dy / length * 10 - 8)
            label.frame = CGRect(x: origin.x, y: origin.y, width: 64, height: 30)
            layer.addSublayer(label)
            textLayers.append(label)
        }
        shapeLayer.path = path.cgPath
        shapeLayer.frame = bounds
    }

    /// Analysis pixels sit on a stride grid of the unrotated buffer. The preview layer applies video gravity.
    private func viewPoint(_ imagePoint: Point2D) -> CGPoint {
        let stride = CGFloat(analysisStride)
        let normalized = CGPoint(
            x: imagePoint.x * stride / bufferSize.width,
            y: imagePoint.y * stride / bufferSize.height
        )
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: normalized)
    }

    private func makeLabel(shoulder: String, root: String) -> CATextLayer {
        let label = CATextLayer()
        label.string = "\(shoulder)\n\(root)"
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.fontSize = 11
        label.foregroundColor = UIColor(red: 0.96, green: 0.93, blue: 0.84, alpha: 1).cgColor
        label.backgroundColor = UIColor.black.withAlphaComponent(0.62).cgColor
        label.cornerRadius = 4
        label.alignmentMode = .center
        label.isWrapped = true
        label.contentsScale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        label.masksToBounds = true
        return label
    }
}
