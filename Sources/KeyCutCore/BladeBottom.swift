import Foundation

/// The blade spine found in a photo. Shoulder on the left, blade to the right.
public struct BladeBottom: Equatable, Sendable {
    /// Clockwise degrees of the edge from +X. Image Y grows downward.
    public var angleDegrees: Double
    /// Signed pixels from the crosshair to the edge in the leveled frame. Positive is above the crosshair, toward the cuts.
    public var offsetPixels: Double
    public var spanPixels: Double
}

/// Every contour point considered, and the ones that lie on the chosen bottom edge.
public struct BladeBottomSearch: Equatable, Sendable {
    public var edges: [Point2D]
    public var selected: [Point2D]
    public var bottom: BladeBottom?

    public static let empty = BladeBottomSearch(edges: [], selected: [], bottom: nil)
}

public enum BladeBottomFinder {
    /// Picks the long, nearly horizontal outline nearest the shoulder.
    /// A parallel line higher on the blade, toward the cuts, is the face reflection and loses.
    public static func choose(polylines: [[Point2D]], shoulder: Point2D) -> BladeBottomSearch {
        var considered: [Point2D] = []
        var fits: [LineFit] = []
        for polyline in polylines {
            for run in straightRuns(polyline) {
                guard let fit = fitLine(run, shoulder: shoulder), fit.span >= minimumSpan else { continue }
                considered.append(contentsOf: fit.points)
                fits.append(fit)
            }
        }
        let merged = mergeCollinear(fits, shoulder: shoulder)
        print("[KeyCut] bottom fragments \(fits.count) merged \(merged.count)")
        for fit in merged where fit.span >= minimumSpan {
            print(String(
                format: "[KeyCut] bottom candidate %+.1f° offset %+.0f residual %.1f span %.0f points %d %@",
                fit.angle, fit.offset, fit.residual, fit.span, fit.points.count, fit.straight ? "straight" : "rejected"
            ))
        }
        let straight = merged.filter(\.straight)
        let longest = straight.map(\.span).max() ?? 0
        let longEnough = straight.filter { $0.span >= longest * 0.7 }
        let onTheOutline = longEnough.filter { $0.offset <= maximumOffsetAbove && $0.offset >= -maximumOffsetBelow }
        guard let chosen = onTheOutline.min(by: nearerTheBreak) else {
            print("[KeyCut] bottom failed, \(fits.count) fragments but none join into a long straight line")
            return BladeBottomSearch(edges: considered, selected: [], bottom: nil)
        }
        print(String(
            format: "[KeyCut] bottom chose %+.1f° offset %+.1f px residual %.1f span %.0f points %d",
            chosen.angle, chosen.offset, chosen.residual, chosen.span, chosen.points.count
        ))
        return BladeBottomSearch(
            edges: considered,
            selected: chosen.points,
            bottom: BladeBottom(angleDegrees: chosen.angle, offsetPixels: chosen.offset, spanPixels: chosen.span)
        )
    }
}

private let minimumSpan = 80.0
/// The mark sits on the bottom edge. A line farther above it is the reflection on the blade face.
private let maximumOffsetAbove = 24.0
/// The mark may sit a little above the metal. A line farther below is background.
private let maximumOffsetBelow = 48.0

private struct LineFit {
    var angle: Double
    var offset: Double
    var residual: Double
    var span: Double
    var points: [Point2D]
    var straight: Bool
}

/// Same distance above the mark costs more than the same distance below it, so the lower outline wins.
private func nearerTheBreak(_ lhs: LineFit, _ rhs: LineFit) -> Bool {
    let left = breakCost(lhs.offset)
    let right = breakCost(rhs.offset)
    if abs(left - right) > 1 { return left < right }
    return lhs.span > rhs.span
}

private func breakCost(_ offset: Double) -> Double {
    if offset > 0 { return offset * 3 }
    return -offset
}

/// Joins pieces of one edge that Canny split. A long black-to-gold line often arrives as many short chains.
private func mergeCollinear(_ fits: [LineFit], shoulder: Point2D) -> [LineFit] {
    var clusters: [LineFit] = []
    for fit in fits where abs(fit.angle) <= 8 {
        if let index = clusters.firstIndex(where: { cluster in
            abs(cluster.angle - fit.angle) <= 2.5 && abs(cluster.offset - fit.offset) <= 8
        }) {
            let combined = clusters[index].points + fit.points
            if let refit = fitLine(combined, shoulder: shoulder) {
                clusters[index] = refit
            }
        } else {
            clusters.append(fit)
        }
    }
    return clusters
}

/// Breaks a contour where it turns, so a straight bottom can be separated from the cuts.
private func straightRuns(_ points: [Point2D]) -> [[Point2D]] {
    guard points.count >= 2 else { return points.isEmpty ? [] : [points] }
    var runs: [[Point2D]] = [[points[0]]]
    var runHeading: Double?
    for index in 1..<points.count {
        let previous = points[index - 1]
        let current = points[index]
        let dx = current.x - previous.x
        let dy = current.y - previous.y
        let length = hypot(dx, dy)
        guard length > 0.5 else {
            runs[runs.count - 1].append(current)
            continue
        }
        let angle = atan2(dy, dx)
        if let runHeading, abs(angleDifference(angle, runHeading)) > 25 * .pi / 180 {
            runs.append([previous, current])
        } else {
            runs[runs.count - 1].append(current)
        }
        runHeading = angle
    }
    return runs.filter { $0.count >= 2 }
}

private func angleDifference(_ lhs: Double, _ rhs: Double) -> Double {
    var delta = lhs - rhs
    while delta > .pi { delta -= 2 * .pi }
    while delta < -.pi { delta += 2 * .pi }
    return delta
}

private func fitLine(_ points: [Point2D], shoulder: Point2D) -> LineFit? {
    let usable = points.filter { $0.x >= shoulder.x - 8 }
    guard usable.count >= 2 else { return nil }
    var sumX = 0.0
    var sumY = 0.0
    var sumXX = 0.0
    var sumXY = 0.0
    for point in usable {
        sumX += point.x
        sumY += point.y
        sumXX += point.x * point.x
        sumXY += point.x * point.y
    }
    let count = Double(usable.count)
    let denominator = sumXX - sumX * sumX / count
    guard abs(denominator) > 1 else { return nil }
    let slope = (sumXY - sumX * sumY / count) / denominator
    let angle = atan(slope) * 180 / .pi
    let radians = angle * .pi / 180
    let cosine = cos(radians)
    let sine = sin(radians)
    var heights: [Double] = []
    var alongs: [Double] = []
    heights.reserveCapacity(usable.count)
    for point in usable {
        let dx = point.x - shoulder.x
        let dy = point.y - shoulder.y
        let along = dx * cosine + dy * sine
        guard along > 0 else { continue }
        alongs.append(along)
        heights.append(dx * sine - dy * cosine)
    }
    guard alongs.count >= 2, let low = alongs.min(), let high = alongs.max() else { return nil }
    let span = high - low
    let offset = heights.reduce(0, +) / Double(heights.count)
    var square = 0.0
    for height in heights {
        let delta = height - offset
        square += delta * delta
    }
    let residual = (square / Double(heights.count)).squareRoot()
    let straight = abs(angle) <= 8 && span >= minimumSpan && residual <= 4
    return LineFit(angle: angle, offset: offset, residual: residual, span: span, points: usable, straight: straight)
}
