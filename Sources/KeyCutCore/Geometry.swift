import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct Point2D: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(0, 0)

    public static func + (lhs: Point2D, rhs: Point2D) -> Point2D {
        Point2D(lhs.x + rhs.x, lhs.y + rhs.y)
    }

    public static func - (lhs: Point2D, rhs: Point2D) -> Point2D {
        Point2D(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    public static func * (lhs: Point2D, rhs: Double) -> Point2D {
        Point2D(lhs.x * rhs, lhs.y * rhs)
    }

    public func dot(_ other: Point2D) -> Double {
        x * other.x + y * other.y
    }

    public func length() -> Double {
        hypot(x, y)
    }

    public func normalized() -> Point2D {
        let len = length()
        guard len > 1e-12 else { return .zero }
        return Point2D(x / len, y / len)
    }

    public func rotated90CCW() -> Point2D {
        Point2D(-y, x)
    }
}

public struct Size2D: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Maps a pixel in an image onto a view that uses aspect-fill (the same crop as
/// `AVCaptureVideoPreviewLayer` video gravity `.resizeAspectFill`).
public enum AspectFill {
    public static func imageToView(point: Point2D, image: Size2D, view: Size2D) -> Point2D {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else {
            return point
        }
        let scale = max(view.width / image.width, view.height / image.height)
        let xOffset = (view.width - image.width * scale) / 2
        let yOffset = (view.height - image.height * scale) / 2
        return Point2D(point.x * scale + xOffset, point.y * scale + yOffset)
    }

    public static func viewToImage(point: Point2D, image: Size2D, view: Size2D) -> Point2D {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else {
            return point
        }
        let scale = max(view.width / image.width, view.height / image.height)
        let xOffset = (view.width - image.width * scale) / 2
        let yOffset = (view.height - image.height * scale) / 2
        return Point2D((point.x - xOffset) / scale, (point.y - yOffset) / scale)
    }
}

public struct BinaryRaster: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        if pixels.count == width * height {
            self.pixels = pixels
        } else {
            self.pixels = [UInt8](repeating: 0, count: max(0, width * height))
        }
    }

    public func filled(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return pixels[y * width + x] != 0
    }
}

public enum Rasterizer {
    /// Fills a closed polygon. Image coordinates, origin top-left, y down.
    public static func fill(polygon: [Point2D], width: Int, height: Int) -> BinaryRaster {
        guard width > 1, height > 1, polygon.count >= 3 else {
            return BinaryRaster(width: max(width, 1), height: max(height, 1), pixels: [UInt8](repeating: 0, count: max(width, 1) * max(height, 1)))
        }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let count = polygon.count
        for y in 0..<height {
            let yScan = Double(y) + 0.5
            var crossings: [Double] = []
            crossings.reserveCapacity(8)
            for index in 0..<count {
                let a = polygon[index]
                let b = polygon[(index + 1) % count]
                let crosses = (a.y <= yScan && b.y > yScan) || (b.y <= yScan && a.y > yScan)
                guard crosses, abs(b.y - a.y) > 1e-12 else { continue }
                let t = (yScan - a.y) / (b.y - a.y)
                crossings.append(a.x + t * (b.x - a.x))
            }
            crossings.sort()
            var pair = 0
            while pair + 1 < crossings.count {
                let start = Int(ceil(crossings[pair] - 1e-9))
                let end = Int(floor(crossings[pair + 1] + 1e-9))
                if end >= start {
                    let x0 = max(0, start)
                    let x1 = min(width - 1, end)
                    if x1 >= x0 {
                        let row = y * width
                        for x in x0...x1 {
                            pixels[row + x] = 1
                        }
                    }
                }
                pair += 2
            }
        }
        return BinaryRaster(width: width, height: height, pixels: pixels)
    }
}
