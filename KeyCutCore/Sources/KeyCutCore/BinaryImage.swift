import Foundation

/// Row-major silhouette. `true` is the key. Coordinate origin is the top-left pixel; y increases downward.
public struct BinaryImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [Bool]

    public init(width: Int, height: Int, pixels: [Bool]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public func contains(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return pixels[y * width + x]
    }

    /// `point` is in pixel coordinates; the pixel that contains it is tested.
    public func contains(_ point: Point2D) -> Bool {
        contains(x: Int(point.x), y: Int(point.y))
    }

    func index(_ x: Int, _ y: Int) -> Int { y * width + x }
}
