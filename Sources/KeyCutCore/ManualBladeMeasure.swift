import Foundation

public struct ManualCut: Equatable, Sendable {
    public var point: Point2D
    public var depthInches: Double
    public var bite: Int
    /// Distance from the shoulder along the blade line.
    public var shoulderDistanceInches: Double
    public var deviationInches: Double
    public var outsideDepthTolerance: Bool
}

public struct ManualBladeReading: Equatable, Sendable {
    public var cuts: [ManualCut]
    public var code: String
    public var pointsPerInch: Double
}

/// Where each cut belongs on the blade line, measured from the shoulder.
public struct BladeStationMarks: Equatable, Sendable {
    public var stations: [Point2D]
    /// Unit direction from the blade line toward the cuts.
    public var up: Point2D
}

public enum ManualBladeMeasure {
    /// Moves five marks onto equal spacing along the blade line and reads each root depth in inches.
    /// Marker 1 to marker 5 is the first-to-last SC1 station span. View Y grows downward.
    public static func adjust(
        shoulder: Point2D,
        bladeEnd: Point2D,
        markers: [Point2D],
        spec: KeySpec
    ) -> ManualBladeReading? {
        guard markers.count == spec.cutCount, spec.cutCount == 5, spec.usedStationsInches.count >= 5 else { return nil }
        let axis = bladeEnd - shoulder
        guard axis.length() > 1 else { return nil }
        let along = axis.normalized()
        let normal = Point2D(along.y, -along.x)
        let projected = markers.map { marker -> (along: Double, height: Double) in
            let relative = marker - shoulder
            return (relative.dot(along), relative.dot(normal))
        }.sorted { $0.along < $1.along }
        let meanAlong = projected.reduce(0) { $0 + $1.along } / Double(projected.count)
        let meanIndex = Double(projected.count - 1) / 2
        var numerator = 0.0
        var denominator = 0.0
        for index in projected.indices {
            let deltaIndex = Double(index) - meanIndex
            numerator += deltaIndex * (projected[index].along - meanAlong)
            denominator += deltaIndex * deltaIndex
        }
        guard denominator > 0 else { return nil }
        let spacing = numerator / denominator
        guard spacing > 1 else { return nil }
        let start = meanAlong - spacing * meanIndex
        let spanInches = spec.usedStationsInches[4] - spec.usedStationsInches[0]
        guard spanInches > 0 else { return nil }
        let pointsPerInch = (spacing * 4) / spanInches
        guard pointsPerInch > 1 else { return nil }
        var cuts: [ManualCut] = []
        cuts.reserveCapacity(projected.count)
        for index in projected.indices {
            let alongPosition = start + Double(index) * spacing
            let height = projected[index].height
            let point = shoulder + along * alongPosition + normal * height
            let depth = height / pointsPerInch
            let match = BittingMath.nearestBite(rootDepthInches: depth, spec: spec)
            cuts.append(ManualCut(
                point: point,
                depthInches: depth,
                bite: match.bite,
                shoulderDistanceInches: alongPosition / pointsPerInch,
                deviationInches: match.deviationInches,
                outsideDepthTolerance: match.outsideTolerance
            ))
        }
        return ManualBladeReading(
            cuts: cuts,
            code: cuts.map { String($0.bite) }.joined(),
            pointsPerInch: pointsPerInch
        )
    }

    /// Root depth of each marker, in input order. The span from the first crosshair to the last, along the blade, is the station span.
    public static func rootDepths(
        shoulder: Point2D,
        bladeEnd: Point2D,
        markers: [Point2D],
        spec: KeySpec
    ) -> [Double]? {
        guard markers.count == spec.cutCount, spec.usedStationsInches.count >= 5 else { return nil }
        let axis = bladeEnd - shoulder
        guard axis.length() > 1 else { return nil }
        let along = axis.normalized()
        let normal = Point2D(along.y, -along.x)
        let projected = markers.map { marker -> (along: Double, height: Double) in
            let relative = marker - shoulder
            return (relative.dot(along), relative.dot(normal))
        }
        let ordered = projected.map(\.along).sorted()
        guard let first = ordered.first, let last = ordered.last else { return nil }
        let spanPoints = last - first
        let spanInches = spec.usedStationsInches[4] - spec.usedStationsInches[0]
        guard spanPoints > 1, spanInches > 0 else { return nil }
        let pointsPerInch = spanPoints / spanInches
        return projected.map { $0.height / pointsPerInch }
    }

    /// Every used station on the blade line. Scale comes from the current marker-1 to marker-5 span.
    public static func stationMarks(
        shoulder: Point2D,
        bladeEnd: Point2D,
        markers: [Point2D],
        spec: KeySpec
    ) -> BladeStationMarks? {
        guard markers.count == spec.cutCount, spec.usedStationsInches.count >= spec.cutCount else { return nil }
        let axis = bladeEnd - shoulder
        guard axis.length() > 1 else { return nil }
        let along = axis.normalized()
        let up = Point2D(along.y, -along.x)
        let ordered = markers.map { ($0 - shoulder).dot(along) }.sorted()
        guard let first = ordered.first, let last = ordered.last else { return nil }
        let spanPoints = last - first
        let spanInches = spec.usedStationsInches[spec.cutCount - 1] - spec.usedStationsInches[0]
        guard spanPoints > 1, spanInches > 0 else { return nil }
        let pointsPerInch = spanPoints / spanInches
        let stations = spec.usedStationsInches.map { shoulder + along * ($0 * pointsPerInch) }
        return BladeStationMarks(stations: stations, up: up)
    }
}
