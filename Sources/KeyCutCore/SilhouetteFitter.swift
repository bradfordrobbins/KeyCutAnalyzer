import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum KeyAnalyzer {
    public static func reading(from raster: BinaryRaster, spec: KeySpec) -> KeyReading? {
        let boundary = boundaryPoints(raster)
        guard boundary.count >= 80 else { return nil }
        guard let fitted = fitPose(boundary: boundary, spec: spec) else { return nil }
        return measure(fitted: fitted, spec: spec)
    }
}

private struct AlongPoint {
    var along: Double
    var height: Double
    var image: Point2D
}

private struct FittedPose {
    var points: [AlongPoint]
    var pose: KeyPose
    var shoulderAlong: Double
    var tipAlong: Double
    var bowAlong: Double
}

private func boundaryPoints(_ raster: BinaryRaster) -> [Point2D] {
    var points: [Point2D] = []
    points.reserveCapacity((raster.width + raster.height) * 2)
    let width = raster.width
    let height = raster.height
    let pixels = raster.pixels
    for y in 0..<height {
        let row = y * width
        for x in 0..<width {
            guard pixels[row + x] != 0 else { continue }
            let left = x == 0 || pixels[row + x - 1] == 0
            let right = x == width - 1 || pixels[row + x + 1] == 0
            let up = y == 0 || pixels[row - width + x] == 0
            let down = y == height - 1 || pixels[row + width + x] == 0
            if left || right || up || down {
                points.append(Point2D(Double(x) + 0.5, Double(y) + 0.5))
            }
        }
    }
    return points
}

private func fitPose(boundary: [Point2D], spec: KeySpec) -> FittedPose? {
    guard let line = longestEdge(points: boundary) else { return nil }
    let normal = interiorNormal(points: boundary, origin: line.origin, direction: line.direction)
    var samples = boundary.map { point -> AlongPoint in
        let offset = point - line.origin
        return AlongPoint(along: offset.dot(line.direction), height: offset.dot(normal), image: point)
    }
    guard let peak = samples.map(\.height).max(), peak > 12 else { return nil }
    let bowThreshold = peak * 0.70
    let bow = samples.filter { $0.height >= bowThreshold }
    guard bow.count > 20 else { return nil }
    let bowMin = bow.map(\.along).min() ?? 0
    let bowMax = bow.map(\.along).max() ?? 0
    let allMin = samples.map(\.along).min() ?? 0
    let allMax = samples.map(\.along).max() ?? 0
    let bowAtLowEnd = abs(bowMin - allMin) <= abs(bowMax - allMax)
    if !bowAtLowEnd {
        samples = samples.map { sample in
            AlongPoint(along: -sample.along, height: sample.height, image: sample.image)
        }
    }
    let tipAxis = (bowAtLowEnd ? line.direction : line.direction * -1).normalized()
    let orientedBow = samples.filter { $0.height >= bowThreshold }
    guard let shoulderAlong = orientedBow.map(\.along).max() else { return nil }
    let bladeBandLow = peak * 0.28
    let bladeBandHigh = peak * 0.58
    let bladeBand = samples.filter {
        $0.along > shoulderAlong + 3
            && $0.height >= bladeBandLow
            && $0.height <= bladeBandHigh
    }
    guard let rawMax = bladeBand.map(\.height).max(), rawMax > 8 else { return nil }
    let crest = bladeBand.filter { $0.height >= rawMax - 1.75 }.map(\.height).sorted()
    guard !crest.isEmpty else { return nil }
    let bladePixels = crest[crest.count / 2]
    let pixelsPerInch = bladePixels / spec.bladeHeightInches
    guard pixelsPerInch > 20, pixelsPerInch < 20000 else { return nil }

    let originAlong = shoulderAlong
    let origin = line.origin + (bowAtLowEnd ? line.direction : line.direction * -1) * originAlong
    let pose = KeyPose(
        origin: origin,
        tipAxis: tipAxis,
        bittingAxis: normal.normalized(),
        pixelsPerInch: pixelsPerInch
    )
    let tipAlong = samples.map(\.along).max() ?? originAlong
    let bowAlong = samples.map(\.along).min() ?? originAlong
    return FittedPose(
        points: samples,
        pose: pose,
        shoulderAlong: originAlong,
        tipAlong: tipAlong,
        bowAlong: bowAlong
    )
}

private func measure(fitted: FittedPose, spec: KeySpec) -> KeyReading? {
    let pose = fitted.pose
    let halfWindow = spec.rootWindowHalfWidthInches * pose.pixelsPerInch
    let upperCutoff = spec.bladeHeightInches * 0.40 * pose.pixelsPerInch
    var cuts: [CutReading] = []
    var overlays: [CutOverlay] = []
    var bites: [Int] = []
    cuts.reserveCapacity(spec.cutCount)

    for index in 0..<spec.cutCount {
        let station = spec.usedStationsInches[index]
        let center = fitted.shoulderAlong + station * pose.pixelsPerInch
        var rootPixels = Double.greatestFiniteMagnitude
        for point in fitted.points where point.height > upperCutoff && abs(point.along - center) <= halfWindow {
            rootPixels = min(rootPixels, point.height)
        }
        guard rootPixels.isFinite else { return nil }
        let rootInches = rootPixels / pose.pixelsPerInch
        guard rootInches > 0.12, rootInches < 0.42 else { return nil }
        let match = BittingMath.nearestBite(rootDepthInches: rootInches, spec: spec)
        let rootMillimeters = Units.millimeters(fromInches: rootInches)
        let specMillimeters = spec.rootDepthMillimeters(bite: match.bite)
        bites.append(match.bite)
        cuts.append(CutReading(
            index: index + 1,
            bite: match.bite,
            shoulderDistanceInches: station,
            shoulderDistanceMillimeters: Units.millimeters(fromInches: station),
            rootDepthInches: rootInches,
            rootDepthMillimeters: rootMillimeters,
            specRootDepthMillimeters: specMillimeters,
            deviationMillimeters: rootMillimeters - specMillimeters,
            outsideDepthTolerance: match.outsideTolerance
        ))
        let bottom = pose.imagePoint(keyX: station, keyY: 0)
        let root = pose.imagePoint(keyX: station, keyY: rootInches)
        let label = pose.imagePoint(keyX: station, keyY: rootInches + 0.06)
        overlays.append(CutOverlay(index: index + 1, bottom: bottom, root: root, label: label))
    }

    let violations = BittingMath.macsViolations(bites: bites, spec: spec)
    let bowAlongInches = (fitted.bowAlong - fitted.shoulderAlong) / pose.pixelsPerInch
    let tipAlongInches = (fitted.tipAlong - fitted.shoulderAlong) / pose.pixelsPerInch
    let overlay = OverlayGeometry(
        bottomStart: pose.imagePoint(keyX: min(bowAlongInches, -0.15), keyY: 0),
        bottomEnd: pose.imagePoint(keyX: max(tipAlongInches, spec.usedStationsInches.last ?? 0.9), keyY: 0),
        shoulderStart: pose.imagePoint(keyX: 0, keyY: -0.04),
        shoulderEnd: pose.imagePoint(keyX: 0, keyY: spec.bladeHeightInches + 0.08),
        cuts: overlays
    )
    return KeyReading(
        specID: spec.id,
        code: bites.map(String.init).joined(),
        cuts: cuts,
        macsViolations: violations,
        macsWarning: BittingMath.macsWarning(violations: violations, spec: spec),
        pose: pose,
        overlay: overlay
    )
}

private struct EdgeLine {
    var origin: Point2D
    var direction: Point2D
}

private func longestEdge(points: [Point2D]) -> EdgeLine? {
    guard points.count >= 2 else { return nil }
    var generator = SplitMix64(seed: 0x5C1A_7E11)
    let iterations = 280
    var bestScore = -Double.greatestFiniteMagnitude
    var bestDirection = Point2D(1, 0)
    var bestOrigin = points[0]
    let threshold = 1.85
    let sampleCap = min(points.count, 6000)
    let step = max(1, points.count / sampleCap)

    for _ in 0..<iterations {
        let firstIndex = generator.nextInt(points.count)
        var secondIndex = generator.nextInt(points.count)
        if secondIndex == firstIndex { secondIndex = (secondIndex + 1) % points.count }
        let a = points[firstIndex]
        let b = points[secondIndex]
        let delta = b - a
        let span = delta.length()
        guard span > 40 else { continue }
        let direction = delta * (1 / span)
        var count = 0
        var minAlong = Double.greatestFiniteMagnitude
        var maxAlong = -Double.greatestFiniteMagnitude
        var index = 0
        while index < points.count {
            let point = points[index]
            let offset = point - a
            let distance = abs(offset.x * direction.y - offset.y * direction.x)
            if distance <= threshold {
                count += 1
                let along = offset.dot(direction)
                minAlong = min(minAlong, along)
                maxAlong = max(maxAlong, along)
            }
            index += step
        }
        let lineSpan = maxAlong - minAlong
        guard count > 25, lineSpan > 40 else { continue }
        let score = Double(count) * lineSpan
        if score > bestScore {
            bestScore = score
            bestDirection = direction
            bestOrigin = a
        }
    }
    guard bestScore > 0 else { return nil }

    var inliers: [Point2D] = []
    inliers.reserveCapacity(points.count / 3)
    for point in points {
        let offset = point - bestOrigin
        let distance = abs(offset.x * bestDirection.y - offset.y * bestDirection.x)
        if distance <= threshold {
            inliers.append(point)
        }
    }
    guard inliers.count >= 30 else { return nil }
    let refined = principalAxis(inliers)
    return EdgeLine(origin: refined.origin, direction: refined.direction)
}

private func principalAxis(_ points: [Point2D]) -> EdgeLine {
    var meanX = 0.0
    var meanY = 0.0
    for point in points {
        meanX += point.x
        meanY += point.y
    }
    let count = Double(points.count)
    meanX /= count
    meanY /= count
    var covXX = 0.0
    var covXY = 0.0
    var covYY = 0.0
    for point in points {
        let dx = point.x - meanX
        let dy = point.y - meanY
        covXX += dx * dx
        covXY += dx * dy
        covYY += dy * dy
    }
    let angle = 0.5 * atan2(2 * covXY, covXX - covYY)
    let direction = Point2D(cos(angle), sin(angle)).normalized()
    return EdgeLine(origin: Point2D(meanX, meanY), direction: direction)
}

private func interiorNormal(points: [Point2D], origin: Point2D, direction: Point2D) -> Point2D {
    let candidate = direction.rotated90CCW().normalized()
    var score = 0.0
    let step = max(1, points.count / 1500)
    var index = 0
    while index < points.count {
        score += (points[index] - origin).dot(candidate)
        index += step
    }
    return score >= 0 ? candidate : candidate * -1
}

private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(_ upper: Int) -> Int {
        guard upper > 0 else { return 0 }
        return Int(next() % UInt64(upper))
    }
}
