import CoreVideo
import Foundation
import KeyCutCore

struct AnalysisFrame {
    var gray: [UInt8]
    var width: Int
    var height: Int
    var stride: Int
    var bufferWidth: Int
    var bufferHeight: Int
}

enum FrameSegmenter {
    /// Copy a BGRA buffer down to the analysis grid. Call this on the capture queue; the buffer is not retained.
    static func copiedFrame(from pixelBuffer: CVPixelBuffer, maxDimension: Int = 640) -> AnalysisFrame? {
        downsample(pixelBuffer, maxDimension: maxDimension)
    }

    static func reading(gray: [UInt8], width: Int, height: Int, spec: KeySpec) -> KeyReading? {
        guard width > 16, height > 16, gray.count == width * height else { return nil }
        let threshold = otsu(gray)
        let darkCount = gray.reduce(into: 0) { count, pixel in
            if pixel <= threshold { count += 1 }
        }
        let preferDark = darkCount * 2 < gray.count
        if let reading = measure(gray: gray, width: width, height: height, threshold: threshold, darkForeground: preferDark, spec: spec) {
            return reading
        }
        return measure(gray: gray, width: width, height: height, threshold: threshold, darkForeground: !preferDark, spec: spec)
    }

    private static func measure(
        gray: [UInt8],
        width: Int,
        height: Int,
        threshold: UInt8,
        darkForeground: Bool,
        spec: KeySpec
    ) -> KeyReading? {
        var pixels = [Bool](repeating: false, count: gray.count)
        for index in gray.indices {
            let dark = gray[index] <= threshold
            pixels[index] = darkForeground ? dark : !dark
        }
        let image = BinaryImage(width: width, height: height, pixels: pixels)
        return try? KeyMeasurer.measure(image: image, spec: spec)
    }

    private static func otsu(_ pixels: [UInt8]) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for pixel in pixels {
            histogram[Int(pixel)] += 1
        }
        let total = pixels.count
        var sumAll = 0
        for tone in 0..<256 {
            sumAll += tone * histogram[tone]
        }
        var backgroundWeight = 0
        var backgroundSum = 0
        var bestVariance = -1.0
        var best = 128
        for tone in 0..<256 {
            backgroundWeight += histogram[tone]
            if backgroundWeight == 0 { continue }
            let foregroundWeight = total - backgroundWeight
            if foregroundWeight == 0 { break }
            backgroundSum += tone * histogram[tone]
            let backgroundMean = Double(backgroundSum) / Double(backgroundWeight)
            let foregroundMean = Double(sumAll - backgroundSum) / Double(foregroundWeight)
            let difference = backgroundMean - foregroundMean
            let variance = Double(backgroundWeight) * Double(foregroundWeight) * difference * difference
            if variance > bestVariance {
                bestVariance = variance
                best = tone
            }
        }
        return UInt8(best)
    }

    private static func downsample(_ pixelBuffer: CVPixelBuffer, maxDimension: Int) -> AnalysisFrame? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard bufferWidth > 0, bufferHeight > 0, bytesPerRow >= bufferWidth * 4 else { return nil }
        let sampleStride = max(1, max(bufferWidth, bufferHeight) / maxDimension)
        let width = bufferWidth / sampleStride
        let height = bufferHeight / sampleStride
        guard width > 16, height > 16 else { return nil }
        var gray = [UInt8](repeating: 0, count: width * height)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let sourceY = min(bufferHeight - 1, row * sampleStride + sampleStride / 2)
            let sourceRow = bytes.advanced(by: sourceY * bytesPerRow)
            for column in 0..<width {
                let sourceX = min(bufferWidth - 1, column * sampleStride + sampleStride / 2)
                let pixel = sourceRow.advanced(by: sourceX * 4)
                let blue = Int(pixel[0])
                let green = Int(pixel[1])
                let red = Int(pixel[2])
                gray[row * width + column] = UInt8((red * 77 + green * 150 + blue * 29) >> 8)
            }
        }
        return AnalysisFrame(
            gray: gray,
            width: width,
            height: height,
            stride: sampleStride,
            bufferWidth: bufferWidth,
            bufferHeight: bufferHeight
        )
    }
}
