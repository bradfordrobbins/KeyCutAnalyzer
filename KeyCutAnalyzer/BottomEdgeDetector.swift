import CoreImage
import CoreVideo
import KeyCutCore
import Vision

/// The key lifted at the shoulder, plus the outline chains used to find the blade bottom.
struct KeyLift {
    var chains: [[Point2D]]
    var mask: CGImage?
}

/// Photos-style subject lift, then the outline of that mask. Canny is the fallback when the mask is empty.
enum BottomEdgeDetector {
    static func lift(in buffer: CVPixelBuffer, shoulder: Point2D) async -> KeyLift {
        if #available(iOS 18, *) {
            let lifted = await subjectContours(in: buffer, shoulder: shoulder)
            if !lifted.chains.isEmpty {
                return lifted
            }
            KeyCutLog.event("bottom subject mask empty, using canny")
            return KeyLift(chains: cannyContours(in: buffer, shoulder: shoulder), mask: lifted.mask)
        }
        return KeyLift(chains: cannyContours(in: buffer, shoulder: shoulder), mask: nil)
    }

    /// The same foreground-instance mask the Photos sticker uses. One subject, no brass reflections.
    @available(iOS 18, *)
    private static func subjectContours(in buffer: CVPixelBuffer, shoulder: Point2D) async -> KeyLift {
        do {
            let handler = ImageRequestHandler(buffer, orientation: .up)
            let request = GenerateForegroundInstanceMaskRequest()
            guard let mask = try await handler.perform(request) else {
                KeyCutLog.event("bottom subject mask nil")
                return KeyLift(chains: [], mask: nil)
            }
            let width = Double(CVPixelBufferGetWidth(buffer))
            let height = Double(CVPixelBufferGetHeight(buffer))
            let instances = subjectInstances(on: mask, shoulder: shoulder, width: width, height: height)
            guard !instances.isEmpty, let instanceMask = try? mask.generateMask(for: instances) else {
                KeyCutLog.event("bottom subject mask has no instance at the shoulder, \(mask.allInstances.count) elsewhere")
                return KeyLift(chains: [], mask: nil)
            }
            let overlay = SilhouetteExtractor.maskOverlay(from: instanceMask, mappedOnto: buffer)
            let chains = outlineChains(in: instanceMask)
            let scaled = scale(chains, from: instanceMask, onto: buffer)
            let kept = scaled.filter { chain in
                chain.contains { $0.x >= shoulder.x - 8 }
            }
            KeyCutLog.event("bottom subject contours \(kept.count) of \(chains.count)")
            return KeyLift(chains: kept, mask: overlay)
        } catch {
            KeyCutLog.event("bottom subject mask failed \(error.localizedDescription)")
            return KeyLift(chains: [], mask: nil)
        }
    }

    /// Prefer the instance under the shoulder. The mark sits on the edge, so also probe up into the blade.
    @available(iOS 18, *)
    private static func subjectInstances(
        on mask: InstanceMaskObservation,
        shoulder: Point2D,
        width: Double,
        height: Double
    ) -> IndexSet {
        let probes = [
            (shoulder.x + 24, shoulder.y - 16),
            (shoulder.x, shoulder.y)
        ]
        for (x, y) in probes {
            guard width > 1, height > 1 else { break }
            let point = NormalizedPoint(
                x: min(max(x / width, 0), 1),
                y: min(max(1 - y / height, 0), 1)
            )
            let hit = mask.instanceAtPoint(point)
            if !hit.isEmpty {
                return hit
            }
        }
        return []
    }

    private static func cannyContours(in buffer: CVPixelBuffer, shoulder: Point2D) -> [[Point2D]] {
        guard let edges = cannyEdges(of: buffer) else {
            KeyCutLog.event("bottom canny failed")
            return []
        }
        let chains = outlineChains(in: edges)
        let kept = chains.filter { chain in
            chain.contains { $0.x >= shoulder.x - 8 }
        }
        KeyCutLog.event("bottom canny contours \(kept.count) of \(chains.count)")
        return kept
    }

    private static func cannyEdges(of buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let source = CIImage(cvPixelBuffer: buffer)
        let grayscale = source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        // A brightness ceiling flattens the face reflection. The dark-to-metal step at the outline stays.
        let capped = grayscale.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 0.40, y: 0.40, z: 0.40, w: 1)
        ])
        let prepared = capped.cropped(to: source.extent).clampedToExtent()
        guard let canny = CIFilter(name: "CICannyEdgeDetector") else { return nil }
        canny.setValue(prepared, forKey: kCIInputImageKey)
        canny.setValue(1.2, forKey: "inputGaussianSigma")
        canny.setValue(false, forKey: "inputPerceptual")
        canny.setValue(0.18, forKey: "inputThresholdHigh")
        canny.setValue(0.08, forKey: "inputThresholdLow")
        canny.setValue(2, forKey: "inputHysteresisPasses")
        guard let output = canny.outputImage?.cropped(to: source.extent) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let destination = pixelBuffer(width: width, height: height) else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        context.render(
            output,
            to: destination,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return destination
    }

    private static func outlineChains(in buffer: CVPixelBuffer) -> [[Point2D]] {
        let longest = max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        var chains = contourChains(in: buffer, detectsDarkOnLight: false, maximumDimension: longest)
        if chains.isEmpty {
            chains = contourChains(in: buffer, detectsDarkOnLight: true, maximumDimension: longest)
        }
        return chains
    }

    private static func scale(
        _ chains: [[Point2D]],
        from mask: CVPixelBuffer,
        onto source: CVPixelBuffer
    ) -> [[Point2D]] {
        let maskWidth = Double(CVPixelBufferGetWidth(mask))
        let maskHeight = Double(CVPixelBufferGetHeight(mask))
        guard maskWidth > 1, maskHeight > 1 else { return [] }
        let scaleX = Double(CVPixelBufferGetWidth(source)) / maskWidth
        let scaleY = Double(CVPixelBufferGetHeight(source)) / maskHeight
        guard abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001 else { return chains }
        return chains.map { chain in
            chain.map { Point2D($0.x * scaleX, $0.y * scaleY) }
        }
    }

    private static func contourChains(
        in buffer: CVPixelBuffer,
        detectsDarkOnLight: Bool,
        maximumDimension: Int
    ) -> [[Point2D]] {
        let request = VNDetectContoursRequest()
        request.maximumImageDimension = maximumDimension
        request.contrastAdjustment = 1
        request.detectsDarkOnLight = detectsDarkOnLight
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            KeyCutLog.event("bottom contours failed \(error.localizedDescription)")
            return []
        }
        guard let observation = request.results?.first as? VNContoursObservation else { return [] }
        let width = Double(CVPixelBufferGetWidth(buffer))
        let height = Double(CVPixelBufferGetHeight(buffer))
        var chains: [[Point2D]] = []
        for contour in observation.topLevelContours {
            collect(contour, width: width, height: height, into: &chains)
        }
        return chains
    }

    private static func collect(_ contour: VNContour, width: Double, height: Double, into chains: inout [[Point2D]]) {
        let points = contour.normalizedPoints.map { point in
            Point2D(Double(point.x) * width, (1 - Double(point.y)) * height)
        }
        if points.count >= 2 {
            chains.append(points)
        }
        for child in contour.childContours {
            collect(child, width: width, height: height, into: &chains)
        }
    }

    private static func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &buffer
        ) == kCVReturnSuccess else { return nil }
        return buffer
    }
}
