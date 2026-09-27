import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum KeyAnalyzer {
    public static func reading(from raster: BinaryRaster, spec: KeySpec) -> KeyReading? {
        reading(fromBoundary: boundaryPoints(raster), spec: spec)
    }

    /// Fits the blade from an outline already in image pixels. A Vision contour can be passed
    /// through directly so the shoulder line and each cut are not re-sampled from a coarse raster.
    public static func reading(fromBoundary points: [Point2D], spec: KeySpec) -> KeyReading? {
        guard points.count >= 80 else { return nil }
        guard let fitted = fitPose(boundary: points, spec: spec) else { return nil }
        return measure(fitted: fitted, spec: spec)
    }

    /// Nudges scale, rotation, and pan around the blank the user lined up, then measures.
    /// Corrections stay inside a few degrees, a few percent of scale, and a few hundredths of an inch.
    public static func reading(
        fromBoundary points: [Point2D],
        alignedNear template: KeyPose,
        spec: KeySpec
    ) -> (reading: KeyReading, alignment: BlankAlignment)? {
        guard points.count >= 80, template.pixelsPerInch > 20 else { return nil }
        let samples = stride(from: 0, to: points.count, by: max(1, points.count / 1600)).map { points[$0] }
        let segments = blankSegments()
        guard let snapped = snap(samples: samples, near: template, segments: segments) else { return nil }
        let along = points.map { point -> AlongPoint in
            let offset = point - snapped.pose.origin
            return AlongPoint(
                along: offset.dot(snapped.pose.tipAxis),
                height: offset.dot(snapped.pose.bittingAxis),
                image: point
            )
        }
        let fitted = FittedPose(
            points: along,
            pose: snapped.pose,
            shoulderAlong: 0,
            tipAlong: along.map(\.along).max() ?? 0,
            bowAlong: along.map(\.along).min() ?? 0
        )
        guard let reading = measure(fitted: fitted, spec: spec) else { return nil }
        return (reading, snapped.alignment)
    }
}

public struct BlankAlignment: Equatable, Sendable {
    public let rotationDegrees: Double
    public let scale: Double
    public let panAlongInches: Double
    public let panBittingInches: Double
}

private struct SnappedBlank {
    var pose: KeyPose
    var alignment: BlankAlignment
}

private func blankSegments() -> [(Point2D, Point2D)] {
    let outline = SyntheticKey.blankOutline()
    guard outline.count >= 2 else { return [] }
    let blade = KeyBlanks.sc1.bladeWidthInches
    let crestEnd = 0.18
    var segments: [(Point2D, Point2D)] = []
    let closed = outline + [outline[0]]
    for index in 0..<(closed.count - 1) {
        let start = closed[index]
        let end = closed[index + 1]
        let alongBladeTop = abs(start.y - end.y) < 0.002
            && abs(start.y - blade) < 0.002
            && min(start.x, end.x) <= 0.02
            && max(start.x, end.x) > crestEnd
        if alongBladeTop {
            let left = min(start.x, end.x)
            segments.append((Point2D(left, blade), Point2D(left + crestEnd, blade)))
        } else {
            segments.append((start, end))
        }
    }
    return segments
}

private func snap(samples: [Point2D], near template: KeyPose, segments: [(Point2D, Point2D)]) -> SnappedBlank? {
    let minimum = max(40, samples.count / 3)
    var bestScore = 0
    var bestCorrection = Double.greatestFiniteMagnitude
    var best: SnappedBlank?
    func consider(rotation: Double, scale: Double, panAlong: Double, panBitting: Double) {
        let pose = posed(template, rotation: rotation, scale: scale, panAlong: panAlong, panBitting: panBitting)
        let score = blankInliers(points: samples, pose: pose, segments: segments)
        let correction = abs(rotation) / 5 + abs(scale - 1) / 0.06 + (abs(panAlong) + abs(panBitting)) / 0.05
        guard score > bestScore || (score == bestScore && correction < bestCorrection) else { return }
        bestScore = score
        bestCorrection = correction
        best = SnappedBlank(
            pose: pose,
            alignment: BlankAlignment(
                rotationDegrees: rotation,
                scale: scale,
                panAlongInches: panAlong,
                panBittingInches: panBitting
            )
        )
    }
    let coarseRotations = [-5.0, -2.5, 0.0, 2.5, 5.0]
    let coarseScales = [0.94, 0.97, 1.0, 1.03, 1.06]
    let coarsePans = [-0.05, 0.0, 0.05]
    for rotation in coarseRotations {
        for scale in coarseScales {
            for panAlong in coarsePans {
                for panBitting in coarsePans {
                    consider(rotation: rotation, scale: scale, panAlong: panAlong, panBitting: panBitting)
                }
            }
        }
    }
    if let coarse = best {
        let fineRotations = [-1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5]
        let fineScales = [-0.02, -0.01, 0.0, 0.01, 0.02]
        let finePans = [-0.02, -0.01, 0.0, 0.01, 0.02]
        for rotation in fineRotations {
            for scale in fineScales {
                for panAlong in finePans {
                    for panBitting in finePans {
                        consider(
                            rotation: coarse.alignment.rotationDegrees + rotation,
                            scale: coarse.alignment.scale + scale,
                            panAlong: coarse.alignment.panAlongInches + panAlong,
                            panBitting: coarse.alignment.panBittingInches + panBitting
                        )
                    }
                }
            }
        }
    }
    guard bestScore >= minimum, let best else { return nil }
    return best
}

private func posed(_ template: KeyPose, rotation: Double, scale: Double, panAlong: Double, panBitting: Double) -> KeyPose {
    let radians = rotation * .pi / 180
    let cosine = cos(radians)
    let sine = sin(radians)
    func turn(_ axis: Point2D) -> Point2D {
        Point2D(cosine * axis.x - sine * axis.y, sine * axis.x + cosine * axis.y).normalized()
    }
    let tip = turn(template.tipAxis)
    let bitting = turn(template.bittingAxis)
    let pixelsPerInch = template.pixelsPerInch * scale
    return KeyPose(
        origin: template.origin + tip * (panAlong * pixelsPerInch) + bitting * (panBitting * pixelsPerInch),
        tipAxis: tip,
        bittingAxis: bitting,
        pixelsPerInch: pixelsPerInch
    )
}

private func blankInliers(points: [Point2D], pose: KeyPose, segments: [(Point2D, Point2D)]) -> Int {
    let tolerance = 0.02
    var count = 0
    for point in points {
        let offset = point - pose.origin
        let key = Point2D(offset.dot(pose.tipAxis) / pose.pixelsPerInch, offset.dot(pose.bittingAxis) / pose.pixelsPerInch)
        for segment in segments where segmentDistance(key, segment.0, segment.1) <= tolerance {
            count += 1
            break
        }
    }
    return count
}

private func segmentDistance(_ point: Point2D, _ start: Point2D, _ end: Point2D) -> Double {
    let edge = end - start
    let lengthSquared = edge.dot(edge)
    if lengthSquared < 1e-12 {
        return (point - start).length()
    }
    let t = min(1, max(0, (point - start).dot(edge) / lengthSquared))
    return (point - (start + edge * t)).length()
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
    // The blade bottom follows the key, so ignore long edges that are not along the key.
    let axis = principalAxis(boundary)
    guard let line = longestEdge(points: boundary, alignedWith: axis.direction)
        ?? longestEdge(points: boundary, alignedWith: nil) else { return nil }
    let normal = interiorNormal(points: boundary, origin: line.origin, direction: line.direction)
    var samples = boundary.map { point -> AlongPoint in
        let offset = point - line.origin
        return AlongPoint(along: offset.dot(line.direction), height: offset.dot(normal), image: point)
    }
    guard let peak = samples.map(\.height).max(), peak > 12 else { return nil }
    let lowEnd = medianPlateau(samples, from: 0, to: 0.22)
    let highEnd = medianPlateau(samples, from: 0.78, to: 1)
    let bowAtLowEnd = lowEnd.isFinite && highEnd.isFinite ? lowEnd >= highEnd : true
    if !bowAtLowEnd {
        samples = samples.map { sample in
            AlongPoint(along: -sample.along, height: sample.height, image: sample.image)
        }
    }
    let tipAxis = (bowAtLowEnd ? line.direction : line.direction * -1).normalized()
    // The shoulder is the step from the tall bow down to the blade, not the end of the tallest blob.
    guard let shoulderAlong = shoulderStep(samples) else { return nil }
    let tipAlong = samples.map(\.along).max() ?? shoulderAlong
    let bladeBodyEnd = shoulderAlong + (tipAlong - shoulderAlong) * 0.82
    let bladeBody = samples.filter { $0.along > shoulderAlong + 3 && $0.along < bladeBodyEnd }
    guard let bodyMax = bladeBody.map(\.height).max(), bodyMax > 8 else { return nil }
    let crest = bladeBody.filter { $0.height >= bodyMax - 1.75 }.map(\.height).sorted()
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
        var rootPixels = minimumBittingHeight(around: center, halfWidth: halfWindow, upperCutoff: upperCutoff, points: fitted.points)
        if !rootPixels.isFinite {
            rootPixels = minimumBittingHeight(
                around: center,
                halfWidth: 0.08 * pose.pixelsPerInch,
                upperCutoff: upperCutoff,
                points: fitted.points
            )
        }
        guard rootPixels.isFinite, rootPixels < 1_000_000 else { return nil }
        let rootInches = rootPixels / pose.pixelsPerInch
        let flat = rootFlat(around: center, rootPixels: rootPixels, fitted: fitted, spec: spec)
        let offsetInches = (flat.centerAlong - fitted.shoulderAlong) / pose.pixelsPerInch
        let widthInches = flat.widthPixels / pose.pixelsPerInch
        let match = BittingMath.nearestBite(rootDepthInches: rootInches, spec: spec)
        let rootMillimeters = Units.millimeters(fromInches: rootInches)
        let specMillimeters = spec.rootDepthMillimeters(bite: match.bite)
        bites.append(match.bite)
        cuts.append(CutReading(
            index: index + 1,
            bite: match.bite,
            shoulderDistanceInches: offsetInches,
            shoulderDistanceMillimeters: Units.millimeters(fromInches: offsetInches),
            rootDepthInches: rootInches,
            rootDepthMillimeters: rootMillimeters,
            specRootDepthMillimeters: specMillimeters,
            deviationMillimeters: rootMillimeters - specMillimeters,
            outsideDepthTolerance: match.outsideTolerance,
            cutWidthMillimeters: Units.millimeters(fromInches: widthInches)
        ))
        let halfWidth = max(widthInches, spec.rootFlatInches) / 2
        let bottom = pose.imagePoint(keyX: offsetInches, keyY: 0)
        let root = pose.imagePoint(keyX: offsetInches, keyY: rootInches)
        let label = pose.imagePoint(keyX: offsetInches, keyY: rootInches + 0.04)
        let widthStart = pose.imagePoint(keyX: offsetInches - halfWidth, keyY: rootInches)
        let widthEnd = pose.imagePoint(keyX: offsetInches + halfWidth, keyY: rootInches)
        overlays.append(CutOverlay(
            index: index + 1,
            bottom: bottom,
            root: root,
            label: label,
            widthStart: widthStart,
            widthEnd: widthEnd
        ))
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

private func minimumBittingHeight(around center: Double, halfWidth: Double, upperCutoff: Double, points: [AlongPoint]) -> Double {
    var rootPixels = Double.nan
    for point in points where point.height > upperCutoff && abs(point.along - center) <= halfWidth {
        rootPixels = rootPixels.isFinite ? min(rootPixels, point.height) : point.height
    }
    return rootPixels
}

private struct RootFlat {
    var centerAlong: Double
    var widthPixels: Double
}

/// Span of the root flat around a spec station. The center is the bit offset; the span is the cut width.
private func rootFlat(around center: Double, rootPixels: Double, fitted: FittedPose, spec: KeySpec) -> RootFlat {
    let pixelsPerInch = fitted.pose.pixelsPerInch
    let searchHalf = 0.06 * pixelsPerInch
    let band = max(1.25, 0.003 * pixelsPerInch)
    let upperCutoff = spec.bladeHeightInches * 0.40 * pixelsPerInch
    var low = Double.greatestFiniteMagnitude
    var high = -Double.greatestFiniteMagnitude
    var count = 0
    for point in fitted.points where point.height > upperCutoff && abs(point.along - center) <= searchHalf && abs(point.height - rootPixels) <= band {
        low = min(low, point.along)
        high = max(high, point.along)
        count += 1
    }
    guard count >= 2, high > low else {
        return RootFlat(centerAlong: center, widthPixels: spec.rootFlatInches * pixelsPerInch)
    }
    return RootFlat(centerAlong: (low + high) / 2, widthPixels: high - low)
}

private struct EdgeLine {
    var origin: Point2D
    var direction: Point2D
}

/// Median height of the top edge in a slice of the key. `from` and `to` are fractions of its length.
private func medianPlateau(_ samples: [AlongPoint], from start: Double, to end: Double) -> Double {
    guard let minAlong = samples.map(\.along).min(),
          let maxAlong = samples.map(\.along).max(),
          maxAlong > minAlong else { return .nan }
    let span = maxAlong - minAlong
    let low = minAlong + span * start
    let high = minAlong + span * end
    let bins = 16
    var heights = [Double](repeating: -.infinity, count: bins)
    let width = max(high - low, 1)
    for sample in samples where sample.along >= low && sample.along <= high && sample.height > 1 {
        var index = Int(((sample.along - low) / width) * Double(bins))
        if index < 0 || index >= bins { index = min(max(index, 0), bins - 1) }
        heights[index] = max(heights[index], sample.height)
    }
    let filled = heights.filter(\.isFinite).sorted()
    guard !filled.isEmpty else { return .nan }
    return filled[filled.count / 2]
}

/// Along-coordinate where the bow drops to the blade. The bow is the tall end; the blade is the low plateau toward the tip.
private func shoulderStep(_ samples: [AlongPoint]) -> Double? {
    let bow = medianPlateau(samples, from: 0.02, to: 0.20)
    let blade = medianPlateau(samples, from: 0.55, to: 0.82)
    guard bow.isFinite, blade.isFinite, bow > blade * 1.2, bow - blade > 8 else { return nil }
    let threshold = (bow + blade) / 2
    let bowPoints = samples.filter { $0.height >= threshold }
    guard bowPoints.count > 12, let shoulder = bowPoints.map(\.along).max() else { return nil }
    return shoulder
}

private func longestEdge(points: [Point2D], alignedWith preferred: Point2D? = nil) -> EdgeLine? {
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
        if let preferred {
            let axis = preferred.normalized()
            guard abs(direction.dot(axis)) >= 0.906 else { continue }
        }
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
