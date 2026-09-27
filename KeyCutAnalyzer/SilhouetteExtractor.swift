import CoreGraphics
import CoreVideo
import KeyCutCore
import Vision

struct FrameExtraction: @unchecked Sendable {
    var reading: KeyReading?
    var imageSize: CGSize
    var note: String?
    /// Green tint of the foreground instance, same pixel size as the photo.
    var maskImage: CGImage? = nil
}

enum SilhouetteExtractor {
    /// Preview checks stay coarse so the camera can tell when a key is holding still.
    /// A captured photo is measured at a higher long-side limit, because a root depth is an edge.
    enum Detail {
        case preview
        case still

        fileprivate var contourMaximumDimension: Int {
            switch self {
            case .preview: return 1920
            case .still: return 3200
            }
        }

        fileprivate var fitLongSide: Double {
            switch self {
            case .preview: return 1400
            case .still: return 3200
            }
        }
    }

    /// True when the coarse contour or threshold path can already fit a key. Used to decide
    /// when a still photo is worth taking. The bitting code comes from the still.
    static func containsKey(pixelBuffer: CVPixelBuffer, spec: KeySpec) async -> Bool {
        if #available(iOS 18, *) {
            if await asyncContourContainsKey(pixelBuffer: pixelBuffer, spec: spec) {
                return true
            }
        } else if await Task.detached(priority: .utility, operation: {
            contourOrThresholdReading(pixelBuffer: pixelBuffer, spec: spec, detail: .preview) != nil
        }).value {
            return true
        }
        return thresholdReading(pixelBuffer: pixelBuffer, spec: spec, darkKey: true, detail: .preview) != nil
            || thresholdReading(pixelBuffer: pixelBuffer, spec: spec, darkKey: false, detail: .preview) != nil
    }

    @available(iOS 18, *)
    private static func asyncContourContainsKey(pixelBuffer: CVPixelBuffer, spec: KeySpec) async -> Bool {
        let longest = max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        for darkOnLight in [true, false] {
            var request = DetectContoursRequest()
            request.maximumImageDimension = min(Detail.preview.contourMaximumDimension, max(64, longest))
            request.contrastAdjustment = 1.6
            request.detectsDarkOnLight = darkOnLight
            guard let observation = try? await request.perform(on: pixelBuffer, orientation: .up) else { continue }
            guard let contour = observation.topLevelContours.max(by: {
                boundsArea($0.normalizedPoints) < boundsArea($1.normalizedPoints)
            }) else { continue }
            let polygon = imagePoints(contour.normalizedPoints, from: pixelBuffer, mappedOnto: pixelBuffer)
            guard polygon.count >= 12 else { continue }
            if reading(fromSourcePolygon: polygon, pixelBuffer: pixelBuffer, spec: spec, detail: .preview) != nil {
                return true
            }
        }
        return false
    }

    /// Foreground outline of a framed photo, in that photo's pixels. Used to snap the key onto the blank.
    static func boundary(of pixelBuffer: CVPixelBuffer) async -> [Point2D]? {
        guard #available(iOS 18, *) else { return nil }
        do {
            let handler = ImageRequestHandler(pixelBuffer, orientation: .up)
            let request = GenerateForegroundInstanceMaskRequest()
            guard let mask = try await handler.perform(request) else { return nil }
            let instances = mask.allInstances
            guard !instances.isEmpty, let instanceMask = try? mask.generateMask(for: instances) else { return nil }
            return silhouette(of: instanceMask, mappedOnto: pixelBuffer, maximumCoverage: 0.95)
        } catch {
            KeyCutLog.event("blank alignment mask failed \(error.localizedDescription)")
            return nil
        }
    }

    /// On iOS 27 a tap seeds `GenerateIterativeSegmentationRequest` at `.accurate` and that mask
    /// is measured instead, which isolates one object when the background is not a clean field.
    static func extract(
        pixelBuffer: CVPixelBuffer,
        spec: KeySpec,
        normalizedTopLeftSeed: CGPoint?,
        detail: Detail = .preview
    ) async -> FrameExtraction {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: sourceWidth, height: sourceHeight)
        guard sourceWidth > 2, sourceHeight > 2 else {
            return FrameExtraction(reading: nil, imageSize: imageSize, note: nil)
        }

        if detail == .still {
            let precise = await preciseStillReading(
                pixelBuffer: pixelBuffer,
                spec: spec,
                normalizedTopLeftSeed: normalizedTopLeftSeed
            )
            if let reading = precise.reading {
                return FrameExtraction(reading: reading, imageSize: imageSize, note: precise.note, maskImage: precise.mask)
            }
            KeyCutLog.event("precise still had no reading, using contour fallback")
            let fallback = contourOrThresholdReading(pixelBuffer: pixelBuffer, spec: spec, detail: detail)
            KeyCutLog.event("contour fallback reading=\(fallback != nil)")
            return FrameExtraction(reading: fallback, imageSize: imageSize, note: precise.note, maskImage: precise.mask)
        }

        return FrameExtraction(
            reading: contourOrThresholdReading(pixelBuffer: pixelBuffer, spec: spec, detail: detail),
            imageSize: imageSize,
            note: nil
        )
    }

    /// Still photos use the highest-quality Vision isolation available, then `DetectContoursRequest`
    /// at the photo's own resolution. The resulting outline is fitted directly so cut offset and
    /// width come from the contour instead of a downsampled mask.
    private static func preciseStillReading(
        pixelBuffer: CVPixelBuffer,
        spec: KeySpec,
        normalizedTopLeftSeed: CGPoint?
    ) async -> (reading: KeyReading?, note: String?, mask: CGImage?) {
        if let seed = normalizedTopLeftSeed, #available(iOS 27, *) {
            let started = CFAbsoluteTimeGetCurrent()
            KeyCutLog.event("iterative segmentation start")
            let segmented = await segmentedContourReading(pixelBuffer: pixelBuffer, spec: spec, seedTopLeft: seed)
            KeyCutLog.elapsed("iterative segmentation reading=\(segmented.reading != nil) waiting=\(segmented.waitingForModel)", since: started)
            if let reading = segmented.reading {
                return (reading, nil, nil)
            }
            if segmented.waitingForModel {
                let maskStart = CFAbsoluteTimeGetCurrent()
                let isolated = await isolatedContourReading(pixelBuffer: pixelBuffer, spec: spec, seedTopLeft: seed)
                if let reading = isolated.reading {
                    KeyCutLog.elapsed("foreground mask while model downloads", since: maskStart)
                    return (reading, "Downloading the key-isolation model. Measured from the foreground mask.", isolated.mask)
                }
                KeyCutLog.elapsed("foreground mask while model downloads, no reading", since: maskStart)
                return (nil, "Downloading the key-isolation model. Hold the key in profile.", isolated.mask)
            }
        }

        if #available(iOS 18, *) {
            let maskStart = CFAbsoluteTimeGetCurrent()
            KeyCutLog.event("foreground mask start")
            let isolated = await isolatedContourReading(pixelBuffer: pixelBuffer, spec: spec, seedTopLeft: normalizedTopLeftSeed)
            if let reading = isolated.reading {
                KeyCutLog.elapsed("foreground mask + contours", since: maskStart)
                return (reading, nil, isolated.mask)
            }
            KeyCutLog.elapsed("foreground mask + contours, no reading", since: maskStart)
            let contourStart = CFAbsoluteTimeGetCurrent()
            KeyCutLog.event("full-photo contours start")
            if let reading = await modernContourReading(pixelBuffer: pixelBuffer, spec: spec) {
                KeyCutLog.elapsed("full-photo contours", since: contourStart)
                return (reading, nil, isolated.mask)
            }
            KeyCutLog.elapsed("full-photo contours, no reading", since: contourStart)
            return (nil, nil, isolated.mask)
        }
        return (nil, nil, nil)
    }

    private static func contourOrThresholdReading(pixelBuffer: CVPixelBuffer, spec: KeySpec, detail: Detail) -> KeyReading? {
        if let reading = contourReading(pixelBuffer: pixelBuffer, spec: spec, darkOnLight: true, detail: detail) {
            return reading
        }
        if let reading = contourReading(pixelBuffer: pixelBuffer, spec: spec, darkOnLight: false, detail: detail) {
            return reading
        }
        if let reading = thresholdReading(pixelBuffer: pixelBuffer, spec: spec, darkKey: true, detail: detail) {
            return reading
        }
        return thresholdReading(pixelBuffer: pixelBuffer, spec: spec, darkKey: false, detail: detail)
    }

    private static func contourReading(pixelBuffer: CVPixelBuffer, spec: KeySpec, darkOnLight: Bool, detail: Detail) -> KeyReading? {
        let request = VNDetectContoursRequest()
        request.maximumImageDimension = detail.contourMaximumDimension
        request.contrastAdjustment = 1.6
        request.detectsDarkOnLight = darkOnLight
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNContoursObservation else { return nil }
        guard let contour = largestContour(in: observation) else { return nil }
        let polygon = imagePolygon(from: contour, pixelBuffer: pixelBuffer)
        guard polygon.count >= 12 else { return nil }
        return reading(fromSourcePolygon: polygon, pixelBuffer: pixelBuffer, spec: spec, detail: detail)
    }

    private static func largestContour(in observation: VNContoursObservation) -> VNContour? {
        var best: VNContour?
        var bestArea: Float = 0
        for contour in observation.topLevelContours {
            let area = boundsArea(contour.normalizedPoints)
            if area > bestArea {
                bestArea = area
                best = contour
            }
        }
        return best
    }

    private static func boundsArea(_ points: [SIMD2<Float>]) -> Float {
        guard let first = points.first else { return 0 }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return max(0, maxX - minX) * max(0, maxY - minY)
    }

    /// Vision normalized points use a bottom-left origin. The raster uses top-left, matching the buffer.
    private static func imagePolygon(from contour: VNContour, pixelBuffer: CVPixelBuffer) -> [Point2D] {
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        return contour.normalizedPoints.map { point in
            Point2D(Double(point.x) * width, (1 - Double(point.y)) * height)
        }
    }

    private static func thresholdReading(pixelBuffer: CVPixelBuffer, spec: KeySpec, darkKey: Bool, detail: Detail) -> KeyReading? {
        guard let raster = thresholdRaster(pixelBuffer: pixelBuffer, darkKey: darkKey, detail: detail) else { return nil }
        let scale = workingScale(pixelBuffer: pixelBuffer, fitLongSide: detail.fitLongSide)
        guard let reading = KeyAnalyzer.reading(from: raster.raster, spec: spec) else { return nil }
        return reading.scaled(by: 1 / scale)
    }

    private static func reading(fromSourcePolygon polygon: [Point2D], pixelBuffer: CVPixelBuffer, spec: KeySpec, detail: Detail) -> KeyReading? {
        let scale = workingScale(pixelBuffer: pixelBuffer, fitLongSide: detail.fitLongSide)
        let width = max(2, Int((Double(CVPixelBufferGetWidth(pixelBuffer)) * scale).rounded()))
        let height = max(2, Int((Double(CVPixelBufferGetHeight(pixelBuffer)) * scale).rounded()))
        let scaled = polygon.map { Point2D($0.x * scale, $0.y * scale) }
        let raster = Rasterizer.fill(polygon: scaled, width: width, height: height)
        guard let reading = KeyAnalyzer.reading(from: raster, spec: spec) else { return nil }
        return reading.scaled(by: 1 / scale)
    }

    private static func workingScale(pixelBuffer: CVPixelBuffer, fitLongSide: Double) -> Double {
        let longest = Double(max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
        guard longest > 0 else { return 1 }
        return min(1, fitLongSide / longest)
    }

    private static func thresholdRaster(pixelBuffer: CVPixelBuffer, darkKey: Bool, detail: Detail) -> (raster: BinaryRaster, scale: Double)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let scale = workingScale(pixelBuffer: pixelBuffer, fitLongSide: detail.fitLongSide)
        let width = max(2, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(2, Int((Double(sourceHeight) * scale).rounded()))
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        var histogram = [Int](repeating: 0, count: 256)
        var samples: [UInt8] = []
        samples.reserveCapacity(width * height)
        for y in 0..<height {
            let sourceY = min(sourceHeight - 1, Int(Double(y) / scale))
            for x in 0..<width {
                let sourceX = min(sourceWidth - 1, Int(Double(x) / scale))
                let luma = luminance(pointer, x: sourceX, y: sourceY, bytesPerRow: bytesPerRow)
                histogram[Int(luma)] += 1
                samples.append(luma)
            }
        }
        let threshold = otsu(histogram: histogram, count: samples.count)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for index in samples.indices {
            let foreground = darkKey ? samples[index] < threshold : samples[index] > threshold
            pixels[index] = foreground ? 1 : 0
        }
        return (BinaryRaster(width: width, height: height, pixels: pixels), scale)
    }

    private static func luminance(_ base: UnsafePointer<UInt8>, x: Int, y: Int, bytesPerRow: Int) -> UInt8 {
        let offset = y * bytesPerRow + x * 4
        let blue = Int(base[offset])
        let green = Int(base[offset + 1])
        let red = Int(base[offset + 2])
        return UInt8((red * 77 + green * 150 + blue * 29) >> 8)
    }

    private static func otsu(histogram: [Int], count: Int) -> UInt8 {
        guard count > 0 else { return 128 }
        var sum = 0
        for index in 0..<256 {
            sum += index * histogram[index]
        }
        var sumBackground = 0
        var weightBackground = 0
        var best = 0.0
        var threshold = 128
        for index in 0..<256 {
            weightBackground += histogram[index]
            if weightBackground == 0 { continue }
            let weightForeground = count - weightBackground
            if weightForeground == 0 { break }
            sumBackground += index * histogram[index]
            let meanBackground = Double(sumBackground) / Double(weightBackground)
            let meanForeground = Double(sum - sumBackground) / Double(weightForeground)
            let difference = meanBackground - meanForeground
            let variance = Double(weightBackground) * Double(weightForeground) * difference * difference
            if variance > best {
                best = variance
                threshold = index
            }
        }
        return UInt8(threshold)
    }

    @available(iOS 18, *)
    private static func isolatedContourReading(
        pixelBuffer: CVPixelBuffer,
        spec: KeySpec,
        seedTopLeft: CGPoint?
    ) async -> (reading: KeyReading?, mask: CGImage?) {
        do {
            let handler = ImageRequestHandler(pixelBuffer, orientation: .up)
            let request = GenerateForegroundInstanceMaskRequest()
            let maskStart = CFAbsoluteTimeGetCurrent()
            guard let mask = try await handler.perform(request) else {
                KeyCutLog.elapsed("GenerateForegroundInstanceMaskRequest nil", since: maskStart)
                return (nil, nil)
            }
            KeyCutLog.elapsed("GenerateForegroundInstanceMaskRequest instances=\(mask.allInstances.count)", since: maskStart)
            let instances: IndexSet
            if let seedTopLeft {
                let point = NormalizedPoint(
                    x: min(max(seedTopLeft.x, 0), 1),
                    y: min(max(1 - seedTopLeft.y, 0), 1)
                )
                let hit = mask.instanceAtPoint(point)
                instances = hit.isEmpty ? mask.allInstances : hit
            } else {
                instances = mask.allInstances
            }
            guard !instances.isEmpty else { return (nil, nil) }
            let instanceMask = try? mask.generateMask(for: instances)
            let overlay = instanceMask.flatMap { maskOverlay(from: $0, mappedOnto: pixelBuffer) }
            if overlay != nil {
                KeyCutLog.event("mask overlay ready")
            }
            if let instanceMask, let boundary = silhouette(of: instanceMask, mappedOnto: pixelBuffer) {
                KeyCutLog.event("key silhouette points=\(boundary.count)")
                if let reading = KeyAnalyzer.reading(fromBoundary: boundary, spec: spec),
                   marksLieOnImage(reading, source: pixelBuffer) {
                    KeyCutLog.event("shoulder fit on key silhouette")
                    return (reading, overlay)
                }
                KeyCutLog.event("silhouette did not locate the shoulder")
            } else {
                KeyCutLog.event("key silhouette unavailable")
            }
            let masked: CVPixelBuffer
            if let image = try? mask.generateMaskedImage(
                for: instances,
                imageFrom: handler,
                croppedToInstancesExtent: false
            ) {
                masked = image
            } else if let instanceMask {
                KeyCutLog.event("masked image unavailable, contouring the instance mask")
                masked = instanceMask
            } else {
                KeyCutLog.event("masked image unavailable, contouring the instance mask")
                masked = try mask.generateMask(for: instances)
            }
            let reading = await modernContourReading(pixelBuffer: masked, spec: spec, sourcePixelBuffer: pixelBuffer)
            return (reading, overlay)
        } catch {
            KeyCutLog.event("foreground mask failed \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    @available(iOS 27, *)
    private static func segmentedContourReading(
        pixelBuffer: CVPixelBuffer,
        spec: KeySpec,
        seedTopLeft: CGPoint
    ) async -> (reading: KeyReading?, waitingForModel: Bool) {
        let clampedX = min(max(seedTopLeft.x, 0), 1)
        let clampedY = min(max(seedTopLeft.y, 0), 1)
        let seed = NormalizedPoint(x: clampedX, y: 1 - clampedY)
        let request = GenerateIterativeSegmentationRequest(seedPoint: seed)
        request.qualityLevel = .accurate
        let status = await request.assetStatus
        KeyCutLog.event("segmentation asset status \(status)")
        switch status {
        case .ready:
            break
        case .downloading:
            return (nil, true)
        case .notReady:
            startSegmentationDownload(request)
            return (nil, true)
        case .error(_):
            startSegmentationDownload(request)
            return (nil, true)
        @unknown default:
            return (nil, false)
        }
        do {
            guard let observation = try await request.perform(on: pixelBuffer, orientation: .up) else {
                return (nil, false)
            }
            guard let maskImage = try? observation.cgImage, let maskBuffer = makePixelBuffer(from: maskImage) else {
                return (nil, false)
            }
            let reading = await modernContourReading(pixelBuffer: maskBuffer, spec: spec, sourcePixelBuffer: pixelBuffer)
            return (reading, false)
        } catch {
            return (nil, false)
        }
    }

    @available(iOS 18, *)
    private static func modernContourReading(
        pixelBuffer: CVPixelBuffer,
        spec: KeySpec,
        sourcePixelBuffer: CVPixelBuffer? = nil
    ) async -> KeyReading? {
        let source = sourcePixelBuffer ?? pixelBuffer
        let longest = max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        KeyCutLog.event("DetectContoursRequest \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) max=\(min(4096, max(64, longest)))")
        for darkOnLight in [false, true] {
            var request = DetectContoursRequest()
            request.maximumImageDimension = min(4096, max(64, longest))
            request.contrastAdjustment = 2
            request.detectsDarkOnLight = darkOnLight
            let contourStart = CFAbsoluteTimeGetCurrent()
            do {
                let observation = try await request.perform(on: pixelBuffer, orientation: .up)
                KeyCutLog.elapsed("DetectContoursRequest darkOnLight=\(darkOnLight) contours=\(observation.topLevelContours.count)", since: contourStart)
                let candidates = keyContours(observation.topLevelContours)
                let contours = candidates.isEmpty ? [bestOpenContour(observation.topLevelContours)].compactMap { $0 } : candidates
                for contour in contours {
                    let simplified = (try? contour.polygonApproximation(epsilon: 0.0002)) ?? contour
                    let outline = simplified.normalizedPoints.count >= 80 ? simplified : contour
                    let polygon = insetFromBorder(imagePoints(outline.normalizedPoints, from: pixelBuffer, mappedOnto: source), source: source)
                    if let reading = KeyAnalyzer.reading(fromBoundary: polygon, spec: spec) {
                        if marksLieOnImage(reading, source: source) {
                            return reading
                        }
                        KeyCutLog.event("reading rejected, marks off the photo")
                    }
                }
            } catch {
                KeyCutLog.elapsed("DetectContoursRequest darkOnLight=\(darkOnLight) failed \(error.localizedDescription)", since: contourStart)
                continue
            }
        }
        return nil
    }

    @available(iOS 18, *)
    private static func keyContours(_ contours: [ContoursObservation.Contour]) -> [ContoursObservation.Contour] {
        var ranked: [(contour: ContoursObservation.Contour, area: Float)] = []
        for contour in contours {
            let box = boundsSize(contour.normalizedPoints)
            let area = box.x * box.y
            guard area > 0.015, area < 0.80 else { continue }
            let shortSide = min(box.x, box.y)
            guard shortSide > 0.01 else { continue }
            let aspect = max(box.x, box.y) / shortSide
            guard aspect >= 1.7, aspect <= 9 else { continue }
            ranked.append((contour, area))
        }
        return ranked.sorted { $0.area > $1.area }.prefix(5).map(\.contour)
    }

    private static func boundsSize(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return SIMD2(max(0, maxX - minX), max(0, maxY - minY))
    }

    /// Drops outline points that sit on the image border. Those edges are the frame, not the blade.
    private static func insetFromBorder(_ points: [Point2D], source: CVPixelBuffer) -> [Point2D] {
        let width = Double(CVPixelBufferGetWidth(source))
        let height = Double(CVPixelBufferGetHeight(source))
        let kept = points.filter { $0.x > 4 && $0.y > 4 && $0.x < width - 4 && $0.y < height - 4 }
        return kept.count >= 80 ? kept : points
    }

    /// Translucent green image of the foreground mask, sized to the photo.
    static func maskOverlay(from mask: CVPixelBuffer, mappedOnto source: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, []) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard maskWidth > 2, maskHeight > 2, width > 2, height > 2 else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let bytesPerPixel = max(1, bytesPerRow / max(maskWidth, 1))
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in 0..<height {
            let maskY = min(maskHeight - 1, y * maskHeight / height)
            let maskRow = maskY * bytesPerRow
            // A bitmap context stores its first row at the bottom. The photo stores its first row at the top.
            let destRow = (height - 1 - y) * width * 4
            for x in 0..<width {
                let maskX = min(maskWidth - 1, x * maskWidth / width)
                let offset = maskRow + maskX * bytesPerPixel
                let value = bytesPerPixel == 1
                    ? pointer[offset]
                    : max(pointer[offset], pointer[offset + 1], pointer[min(offset + 2, maskRow + bytesPerRow - 1)])
                guard value > 16 else { continue }
                let index = destRow + x * 4
                pixels[index] = 34
                pixels[index + 1] = 103
                pixels[index + 2] = 52
                pixels[index + 3] = 120
            }
        }
        return context.makeImage()
    }

    /// Outer boundary of the foreground mask, in source-image pixels. This is the key, without the internal edges of the photo.
    private static func silhouette(
        of mask: CVPixelBuffer,
        mappedOnto source: CVPixelBuffer,
        maximumCoverage: Double = 0.75
    ) -> [Point2D]? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, []) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard width > 2, height > 2 else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let bytesPerPixel = max(1, bytesPerRow / max(width, 1))
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var filled = [UInt8](repeating: 0, count: width * height)
        var count = 0
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let offset = row + x * bytesPerPixel
                let value = bytesPerPixel == 1 ? pointer[offset] : max(pointer[offset], pointer[offset + 1], pointer[min(offset + 2, row + bytesPerRow - 1)])
                if value > 16 {
                    filled[y * width + x] = 1
                    count += 1
                }
            }
        }
        let fraction = Double(count) / Double(width * height)
        KeyCutLog.event("mask coverage \(String(format: "%.3f", fraction))")
        guard fraction > 0.01, fraction < maximumCoverage else { return nil }
        var points: [Point2D] = []
        points.reserveCapacity((width + height) * 2)
        let scaleX = Double(CVPixelBufferGetWidth(source)) / Double(width)
        let scaleY = Double(CVPixelBufferGetHeight(source)) / Double(height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                guard filled[row + x] != 0 else { continue }
                let left = x == 0 || filled[row + x - 1] == 0
                let right = x == width - 1 || filled[row + x + 1] == 0
                let up = y == 0 || filled[row - width + x] == 0
                let down = y == height - 1 || filled[row + width + x] == 0
                guard left || right || up || down else { continue }
                points.append(Point2D((Double(x) + 0.5) * scaleX, (Double(y) + 0.5) * scaleY))
            }
        }
        let outline = insetFromBorder(points, source: source)
        guard outline.count >= 80 else { return nil }
        if outline.count <= 12000 { return outline }
        let step = outline.count / 8000
        return stride(from: 0, to: outline.count, by: step).map { outline[$0] }
    }

    @available(iOS 18, *)
    private static func bestOpenContour(_ contours: [ContoursObservation.Contour]) -> ContoursObservation.Contour? {
        var best: ContoursObservation.Contour?
        var bestArea: Float = 0
        for contour in contours {
            let area = boundsArea(contour.normalizedPoints)
            guard area > 0.01, area < 0.90 else { continue }
            if area > bestArea {
                bestArea = area
                best = contour
            }
        }
        return best
    }

    private static func marksLieOnImage(_ reading: KeyReading, source: CVPixelBuffer) -> Bool {
        let width = Double(CVPixelBufferGetWidth(source))
        let height = Double(CVPixelBufferGetHeight(source))
        let points = reading.overlay.cuts.flatMap { [$0.bottom, $0.root, $0.widthStart, $0.widthEnd] }
        guard !points.isEmpty, width > 1, height > 1 else { return false }
        let inside = points.filter {
            $0.x >= -width * 0.02 && $0.x <= width * 1.02 && $0.y >= -height * 0.02 && $0.y <= height * 1.02
        }
        return inside.count >= points.count / 2
    }

    private static func imagePoints(
        _ points: [SIMD2<Float>],
        from buffer: CVPixelBuffer,
        mappedOnto source: CVPixelBuffer
    ) -> [Point2D] {
        let width = Double(CVPixelBufferGetWidth(buffer))
        let height = Double(CVPixelBufferGetHeight(buffer))
        guard width > 1, height > 1 else { return [] }
        let scaleX = Double(CVPixelBufferGetWidth(source)) / width
        let scaleY = Double(CVPixelBufferGetHeight(source)) / height
        return points.map { point in
            Point2D(Double(point.x) * width * scaleX, (1 - Double(point.y)) * height * scaleY)
        }
    }

    private static func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
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

    @available(iOS 27, *)
    private static func startSegmentationDownload(_ request: GenerateIterativeSegmentationRequest) {
        downloadLock.lock()
        let alreadyStarted = segmentationDownloadStarted
        segmentationDownloadStarted = true
        downloadLock.unlock()
        guard !alreadyStarted else { return }
        Task {
            try? await request.downloadAssets()
        }
    }

    private static let downloadLock = NSLock()
    private static var segmentationDownloadStarted = false
}
