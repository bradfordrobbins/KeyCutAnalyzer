import Foundation

/// Image and key-frame point. Image space is x right, y down, in pixels.
/// Key space is x from the shoulder toward the tip, y from the blade bottom toward the bitting.
public struct Point2D: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(x: 0, y: 0)

    public var length: Double { hypot(x, y) }

    public func dot(_ other: Point2D) -> Double {
        x * other.x + y * other.y
    }

    public func rotated90() -> Point2D {
        Point2D(x: -y, y: x)
    }

    public func unit() -> Point2D {
        let magnitude = length
        guard magnitude > 1e-9 else { return .zero }
        return self * (1 / magnitude)
    }

    public static func + (lhs: Point2D, rhs: Point2D) -> Point2D {
        Point2D(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    public static func - (lhs: Point2D, rhs: Point2D) -> Point2D {
        Point2D(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    public static func * (lhs: Point2D, rhs: Double) -> Point2D {
        Point2D(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    public static func * (lhs: Double, rhs: Point2D) -> Point2D {
        rhs * lhs
    }
}

public struct Size2D: Sendable, Equatable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

enum LineFit {
    /// Major-axis direction is unsigned. `normal` is `direction` rotated 90° (also unsigned).
    static func principalAxis(_ points: [Point2D]) -> (centroid: Point2D, direction: Point2D)? {
        guard points.count >= 2 else { return nil }
        var meanX = 0.0
        var meanY = 0.0
        for point in points {
            meanX += point.x
            meanY += point.y
        }
        let count = Double(points.count)
        meanX /= count
        meanY /= count

        var xx = 0.0
        var xy = 0.0
        var yy = 0.0
        for point in points {
            let dx = point.x - meanX
            let dy = point.y - meanY
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }

        // Eigenvector of the covariance for the larger eigenvalue.
        let trace = xx + yy
        let determinant = xx * yy - xy * xy
        let half = 0.5 * trace
        let radical = max(0, half * half - determinant)
        let lambda = half + radical.squareRoot()

        var direction: Point2D
        if abs(xy) > 1e-9 || abs(xx - lambda) > 1e-9 {
            direction = Point2D(x: xy, y: lambda - xx)
            if direction.length < 1e-9 {
                direction = Point2D(x: lambda - yy, y: xy)
            }
        } else {
            direction = Point2D(x: 1, y: 0)
        }
        let unit = direction.unit()
        guard unit.length > 0.5 else { return nil }
        return (Point2D(x: meanX, y: meanY), unit)
    }
}
