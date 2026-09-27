import CoreGraphics
import CoreVideo
import KeyCutCore
import Vision

struct FrameExtraction: Sendable {
    var reading: KeyReading?
    var imageSize: CGSize
    var note: String?
}

enum SilhouetteExtractor {
    /// Live path uses Vision contour detection at the frame's own resolution, because a root
    /// depth is an edge measurement. On iOS 27 a tap seeds `GenerateIterativeSegmentationRequest`
    /// at `.accurate` and that mask is measured instead, which is the current way to isolate one
    /// object when the background is not a clean field.
    static func extract(
        pixelBuffer: CVPixelBuffer,
        spec: KeySpec,
        normalizedTopLeftSeed: CGPoint?
    ) async -> FrameExtraction {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: sourceWidth, height: sourceHeight)
        guard sourceWidth > 2, sourceHeight > 2 else {
            return FrameExtraction(reading: nil, imageSize: imageSize, note: nil)
        }

        if let seed = normalizedTopLeftSeed, #available(iOS 27, *) {
            let segmented = await segmentedReading(pixelBuffer: pixelBuffer, spec: spec, seedTopLeft: seed)
            if let reading = segmented.reading {
                return FrameExtraction(reading: reading, imageSize: imageSize, note: nil)
            }
            if segmented.waitingForModel {
                return FrameExtraction(
                    reading: contourOrThresholdReading(pixelBuffer: pixelBuffer, spec: spec),
                    imageSize: imageSize,
                    note: "Downloading the key-isolation model. Hold the key in profile."
                )
            }
        }

        return FrameExtraction(
            reading: contourOrThresholdReading(pixelBuffer: pixelBuffer, spec: spec),
            imageSize: imageSize,
            note: nil
        )
    }

    private static func contourOrThresholdReading(pixelBuffer: CVPixelBuffer, spec: KeySpec) -> KeyReading? {
        if let reading = contourReading(pixelBuffer: pixelBuffer, spec: spec, darkOnLight: true) {
            return reading
        }
        if let reading = contourReading(pixelBuffer: pixelBuffer, spec: spec, darkOnLight: false) {
            return reading
        }
        if let reading = thresholdReading(pixelBuffer: pixelBuffer, spec: spec, darkKey: true) {
            return reading
        }
        return thresholdReading(pixelBuffer: pixelBuffer, spec: spec, darkKey: false)
    }

    private static func contourReading(pixelBuffer: CVPixelBuffer, spec: KeySpec, darkOnLight: Bool) -> KeyReading? {
        let request = VNDetectContoursRequest()
        request.maximumImageDimension = 1920
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
        return reading(fromSourcePolygon: polygon, pixelBuffer: pixelBuffer, spec: spec)
    }

    private static func largestContour(in observation: VNContoursObservation) -> VNContour? {
        var best: VNContour?
        var bestArea: Float = 0
        let count = observation.topLevelContourCount
        for index in 0..<count {
            guard let contour = try? observation.topLevelContour(at: index) else { continue }
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

    private static func thresholdReading(pixelBuffer: CVPixelBuffer, spec: KeySpec, darkKey: Bool) -> KeyReading? {
        guard let raster = thresholdRaster(pixelBuffer: pixelBuffer, darkKey: darkKey) else { return nil }
        let scale = workingScale(pixelBuffer: pixelBuffer)
        guard let reading = KeyAnalyzer.reading(from: raster.raster, spec: spec) else { return nil }
        return reading.scaled(by: 1 / scale)
    }

    private static func reading(fromSourcePolygon polygon: [Point2D], pixelBuffer: CVPixelBuffer, spec: KeySpec) -> KeyReading? {
        let scale = workingScale(pixelBuffer: pixelBuffer)
        let width = max(2, Int((Double(CVPixelBufferGetWidth(pixelBuffer)) * scale).rounded()))
        let height = max(2, Int((Double(CVPixelBufferGetHeight(pixelBuffer)) * scale).rounded()))
        let scaled = polygon.map { Point2D($0.x * scale, $0.y * scale) }
        let raster = Rasterizer.fill(polygon: scaled, width: width, height: height)
        guard let reading = KeyAnalyzer.reading(from: raster, spec: spec) else { return nil }
        return reading.scaled(by: 1 / scale)
    }

    private static func workingScale(pixelBuffer: CVPixelBuffer) -> Double {
        let longest = Double(max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
        guard longest > 0 else { return 1 }
        return min(1, 1400 / longest)
    }

    private static func thresholdRaster(pixelBuffer: CVPixelBuffer, darkKey: Bool) -> (raster: BinaryRaster, scale: Double)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let scale = workingScale(pixelBuffer: pixelBuffer)
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

    @available(iOS 27, *)
    private static func segmentedReading(
        pixelBuffer: CVPixelBuffer,
        spec: KeySpec,
        seedTopLeft: CGPoint
    ) async -> (reading: KeyReading?, waitingForModel: Bool) {
        let clampedX = min(max(seedTopLeft.x, 0), 1)
        let clampedY = min(max(seedTopLeft.y, 0), 1)
        let seed = NormalizedPoint(x: clampedX, y: 1 - clampedY)
        let request = GenerateIterativeSegmentationRequest(seedPoint: seed)
        request.qualityLevel = .accurate
        switch request.assetStatus {
        case .ready:
            break
        case .downloading:
            return (nil, true)
        case .notReady:
            startSegmentationDownload(request)
            return (nil, true)
        case .error:
            startSegmentationDownload(request)
            return (nil, true)
        @unknown default:
            return (nil, false)
        }
        do {
            guard let observation = try await request.perform(on: pixelBuffer, orientation: .up) else {
                return (nil, false)
            }
            guard let raster = raster(from: observation.cgImage, pixelBuffer: pixelBuffer) else { return (nil, false) }
            guard let reading = KeyAnalyzer.reading(from: raster.raster, spec: spec) else { return (nil, false) }
            return (reading.scaled(by: 1 / raster.scale), false)
        } catch {
            return (nil, false)
        }
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

    private static func raster(from image: CGImage, pixelBuffer: CVPixelBuffer) -> (raster: BinaryRaster, scale: Double)? {
        let maskWidth = image.width
        let maskHeight = image.height
        guard maskWidth > 2, maskHeight > 2 else { return nil }
        var gray = [UInt8](repeating: 0, count: maskWidth * maskHeight)
        let drew = gray.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: maskWidth,
                height: maskHeight,
                bitsPerComponent: 8,
                bytesPerRow: maskWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.translateBy(x: 0, y: CGFloat(maskHeight))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: maskWidth, height: maskHeight))
            return true
        }
        guard drew else { return nil }

        let scale = workingScale(pixelBuffer: pixelBuffer)
        let width = max(2, Int((Double(CVPixelBufferGetWidth(pixelBuffer)) * scale).rounded()))
        let height = max(2, Int((Double(CVPixelBufferGetHeight(pixelBuffer)) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let maskY = min(maskHeight - 1, Int(Double(y) / Double(height) * Double(maskHeight)))
            for x in 0..<width {
                let maskX = min(maskWidth - 1, Int(Double(x) / Double(width) * Double(maskWidth)))
                pixels[y * width + x] = gray[maskY * maskWidth + maskX] >= 128 ? 1 : 0
            }
        }
        return (BinaryRaster(width: width, height: height, pixels: pixels), scale)
    }
}
