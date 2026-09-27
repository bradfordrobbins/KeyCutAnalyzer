import Foundation

/// Profile silhouette of a pin-tumbler key in the key frame:
/// origin at the shoulder on the blade-bottom line, +x toward the tip, +y toward the bitting.
public enum SyntheticKey {
    /// Local-inch contour, bow at negative x. Bitting is whatever bite list is passed in — nothing is hardcoded.
    public static func contour(spec: KeySpec, bitting: [Int]) -> [Point2D] {
        precondition(bitting.count == spec.stationsUsed, "bitting must cover every used station")
        let bladeHeight = spec.bladeHeightInches
        let stations = spec.usedStationsInches
        let bladeLength = stations[stations.count - 1] + 0.38
        let halfFlat = spec.rootFlatInches / 2
        // Walls are steeper than the catalog cutter angle so a deep neighbor cannot erase the next root flat
        // (SC1's 100° included angle meets the next flat right at MACS). The flat itself stays 0.031 in wide.
        let slope = tan(58.0 * .pi / 180)

        func topY(_ x: Double) -> Double {
            var y = bladeHeight
            for index in 0..<stations.count {
                let root = spec.rootDepthsInches[bitting[index]]
                let dx = abs(x - stations[index])
                let cutY = dx <= halfFlat ? root : root + (dx - halfFlat) * slope
                y = min(y, cutY)
            }
            return min(bladeHeight, y)
        }

        var points: [Point2D] = []

        // Rounded bow, entirely on the bow side of the shoulder, taller than the blade.
        let bowLeft = -0.98
        let bowBottom = -0.34
        let bowTop = 0.78
        let radius = 0.22
        points.append(Point2D(x: 0, y: 0))
        points.append(Point2D(x: 0, y: bowBottom + radius))
        appendArc(
            into: &points,
            center: Point2D(x: -radius, y: bowBottom + radius),
            radius: radius,
            from: 0,
            to: -.pi / 2,
            steps: 8
        )
        points.append(Point2D(x: bowLeft + radius, y: bowBottom))
        appendArc(
            into: &points,
            center: Point2D(x: bowLeft + radius, y: bowBottom + radius),
            radius: radius,
            from: -.pi / 2,
            to: -.pi,
            steps: 8
        )
        points.append(Point2D(x: bowLeft, y: bowTop - radius))
        appendArc(
            into: &points,
            center: Point2D(x: bowLeft + radius, y: bowTop - radius),
            radius: radius,
            from: .pi,
            to: .pi / 2,
            steps: 8
        )
        points.append(Point2D(x: -radius, y: bowTop))
        appendArc(
            into: &points,
            center: Point2D(x: -radius, y: bowTop - radius),
            radius: radius,
            from: .pi / 2,
            to: 0,
            steps: 8
        )
        points.append(Point2D(x: 0, y: bladeHeight))

        let step = 0.003
        var x = 0.0
        while x < bladeLength {
            points.append(Point2D(x: x, y: topY(x)))
            x += step
        }
        points.append(Point2D(x: bladeLength, y: topY(bladeLength)))
        // Short tip chamfer. The blade bottom stays the longest straight edge.
        points.append(Point2D(x: bladeLength + 0.045, y: bladeHeight * 0.55))
        points.append(Point2D(x: bladeLength, y: 0))
        points.append(Point2D(x: 0, y: 0))
        return points
    }

    /// Rasterize a posed key. `rotationRadians` is counterclockwise in y-up space before the image y-down flip.
    /// `bowOnRight` mirrors through the shoulder. `bittingDown` flips the bitting side.
    public static func render(
        spec: KeySpec,
        bitting: [Int],
        rotationRadians: Double,
        pixelsPerInch: Double,
        translation: Point2D,
        bowOnRight: Bool,
        bittingDown: Bool,
        margin: Int = 16
    ) -> BinaryImage {
        let local = contour(spec: spec, bitting: bitting)
        let transformed = local.map { point in
            imagePoint(
                local: point,
                rotationRadians: rotationRadians,
                pixelsPerInch: pixelsPerInch,
                translation: translation,
                bowOnRight: bowOnRight,
                bittingDown: bittingDown
            )
        }
        let minX = transformed.map(\.x).min() ?? 0
        let minY = transformed.map(\.y).min() ?? 0
        let maxX = transformed.map(\.x).max() ?? 0
        let maxY = transformed.map(\.y).max() ?? 0
        // Integer shift keeps the fractional pixel phase created by rotation, scale, and translation.
        let shiftX = Double(margin) - floor(minX)
        let shiftY = Double(margin) - floor(minY)
        let placed = transformed.map { Point2D(x: $0.x + shiftX, y: $0.y + shiftY) }
        let width = max(1, Int(ceil((maxX + shiftX))) + margin)
        let height = max(1, Int(ceil((maxY + shiftY))) + margin)
        return Rasterizer.fill(polygon: placed, width: width, height: height)
    }

    static func imagePoint(
        local: Point2D,
        rotationRadians: Double,
        pixelsPerInch: Double,
        translation: Point2D,
        bowOnRight: Bool,
        bittingDown: Bool
    ) -> Point2D {
        var x = local.x
        var y = local.y
        if bowOnRight { x = -x }
        if bittingDown { y = -y }
        let cosine = cos(rotationRadians)
        let sine = sin(rotationRadians)
        let rotatedX = x * cosine - y * sine
        let rotatedY = x * sine + y * cosine
        return Point2D(
            x: rotatedX * pixelsPerInch + translation.x,
            y: -rotatedY * pixelsPerInch + translation.y
        )
    }

    private static func appendArc(
        into points: inout [Point2D],
        center: Point2D,
        radius: Double,
        from: Double,
        to: Double,
        steps: Int
    ) {
        guard steps > 0 else { return }
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let angle = from + (to - from) * t
            points.append(Point2D(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
        }
    }
}
