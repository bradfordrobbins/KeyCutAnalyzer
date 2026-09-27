import Foundation

public struct PoseEstimate: Sendable, Equatable {
    /// Angle of the tip direction in image space (x right, y down), radians.
    public let rotationRadians: Double
    public let pixelsPerInch: Double
    /// Shoulder, on the blade-bottom line, in image pixels.
    public let origin: Point2D
    /// Unit vector toward the tip.
    public let tipDirection: Point2D
    /// Unit vector from the blade bottom toward the bitting.
    public let bittingDirection: Point2D
    public let bladeLengthPixels: Double

    public init(
        rotationRadians: Double,
        pixelsPerInch: Double,
        origin: Point2D,
        tipDirection: Point2D,
        bittingDirection: Point2D,
        bladeLengthPixels: Double
    ) {
        self.rotationRadians = rotationRadians
        self.pixelsPerInch = pixelsPerInch
        self.origin = origin
        self.tipDirection = tipDirection
        self.bittingDirection = bittingDirection
        self.bladeLengthPixels = bladeLengthPixels
    }
}

public struct CutMeasurement: Sendable, Equatable {
    /// 1-based station, bow to tip.
    public let index: Int
    public let shoulderInches: Double
    public let shoulderMillimeters: Double
    public let rootInches: Double
    public let rootMillimeters: Double
    public let nearestBite: Int
    /// Measured root millimeters minus the nearest bite's charted root millimeters.
    public let deviationMillimeters: Double
    public let outsideTolerance: Bool
    public let rootPoint: Point2D
    public let bottomPoint: Point2D

    public var shoulderText: String { KeyMath.formatMillimeters(shoulderMillimeters) }
    public var rootText: String { KeyMath.formatMillimeters(rootMillimeters) }
    public var deviationText: String { String(format: "%+.3f", deviationMillimeters) }
}

public struct KeyReading: Sendable, Equatable {
    public let specID: String
    public let pose: PoseEstimate
    public let cuts: [CutMeasurement]
    /// Five digits, bow to tip.
    public let bittingCode: String
    /// True when any adjacent bites differ by more than the keyway's MACS.
    public let macsExceeded: Bool
}

public enum KeyMeasurementError: Error, Equatable {
    case emptyImage
    case noSilhouette
    case bladeNotFound
    case scaleNotFound
}

public enum KeyMeasurer {
    /// Recover pose and the used stations from a key silhouette.
    /// The key frame origin is the shoulder on the blade bottom, +x toward the tip, +y toward the bitting.
    /// Bow left or right and bitting up or down are both accepted; distance and rotation are not assumed.
    public static func measure(image: BinaryImage, spec: KeySpec) throws -> KeyReading {
        guard image.width > 8, image.height > 8 else { throw KeyMeasurementError.emptyImage }
        guard let blob = largestInteriorBlob(image) else { throw KeyMeasurementError.noSilhouette }
        let contour = ContourTracer.trace(blob)
        guard contour.count > 40 else { throw KeyMeasurementError.bladeNotFound }
        guard let blade = longestStraightRun(contour) else { throw KeyMeasurementError.bladeNotFound }
        let pose = try poseFromBlade(blade, image: blob, spec: spec)
        let cuts = try measureCuts(pose: pose, image: blob, spec: spec)
        let bladeInches = pose.bladeLengthPixels / pose.pixelsPerInch
        guard (0.7...2.2).contains(bladeInches) else { throw KeyMeasurementError.bladeNotFound }
        guard cuts.allSatisfy({ (0.12...0.42).contains($0.rootInches) }) else {
            throw KeyMeasurementError.bladeNotFound
        }
        let bites = cuts.map(\.nearestBite)
        let code = bites.map(String.init).joined()
        return KeyReading(
            specID: spec.id,
            pose: pose,
            cuts: cuts,
            bittingCode: code,
            macsExceeded: !KeyMath.macsViolatingPairs(bites: bites, spec: spec).isEmpty
        )
    }

    private static func poseFromBlade(_ run: [Point2D], image: BinaryImage, spec: KeySpec) throws -> PoseEstimate {
        guard let fit = LineFit.principalAxis(run) else { throw KeyMeasurementError.bladeNotFound }
        var direction = fit.direction
        let projections = run.map { ($0 - fit.centroid).dot(direction) }
        guard let minT = projections.min(), let maxT = projections.max(), maxT - minT > 12 else {
            throw KeyMeasurementError.bladeNotFound
        }
        let endA = fit.centroid + direction * minT
        let endB = fit.centroid + direction * maxT
        let massA = massBeyond(endA, awayFrom: endB, image: image)
        let massB = massBeyond(endB, awayFrom: endA, image: image)
        // The bow is the bulky end past the straight blade bottom.
        let shoulder: Point2D
        let tip: Point2D
        if massA > massB {
            shoulder = endA
            tip = endB
        } else {
            shoulder = endB
            tip = endA
        }
        direction = (tip - shoulder).unit()
        guard direction.length > 0.5 else { throw KeyMeasurementError.bladeNotFound }

        var normal = direction.rotated90()
        let towardBitting = interiorScore(normal, shoulder: shoulder, tip: tip, image: image)
        let away = interiorScore(normal * -1, shoulder: shoulder, tip: tip, image: image)
        if away > towardBitting {
            normal = normal * -1
        }
        guard max(towardBitting, away) > 0 else { throw KeyMeasurementError.bladeNotFound }

        let bladeLength = (tip - shoulder).length
        let pixelsPerInch = try bladeScale(
            shoulder: shoulder,
            direction: direction,
            normal: normal,
            bladeLength: bladeLength,
            image: image,
            spec: spec
        )
        let rotation = atan2(direction.y, direction.x)
        return PoseEstimate(
            rotationRadians: rotation,
            pixelsPerInch: pixelsPerInch,
            origin: shoulder,
            tipDirection: direction,
            bittingDirection: normal,
            bladeLengthPixels: bladeLength
        )
    }

    private static func bladeScale(
        shoulder: Point2D,
        direction: Point2D,
        normal: Point2D,
        bladeLength: Double,
        image: BinaryImage,
        spec: KeySpec
    ) throws -> Double {
        var heights: [Double] = []
        let samples = 180
        for index in 0..<samples {
            let t = bladeLength * (0.04 + 0.90 * Double(index) / Double(samples - 1))
            if let height = topDistance(
                axial: t,
                origin: shoulder,
                direction: direction,
                normal: normal,
                image: image,
                limit: bladeLength
            ) {
                heights.append(height)
            }
        }
        guard heights.count > 20 else { throw KeyMeasurementError.scaleNotFound }
        // The uncut land is the high plateau. Averaging the top slice avoids a 1 px histogram step.
        let sorted = heights.sorted()
        let sliceCount = max(8, sorted.count / 8)
        let top = sorted.suffix(sliceCount)
        let topMedian = top[top.index(top.startIndex, offsetBy: top.count / 2)]
        let land = top.filter { abs($0 - topMedian) <= 1.5 }
        guard !land.isEmpty else { throw KeyMeasurementError.scaleNotFound }
        let bladePixels = land.reduce(0, +) / Double(land.count)
        guard bladePixels > 8 else { throw KeyMeasurementError.scaleNotFound }
        let pixelsPerInch = bladePixels / spec.bladeHeightInches
        guard pixelsPerInch.isFinite, pixelsPerInch > 20 else { throw KeyMeasurementError.scaleNotFound }
        return pixelsPerInch
    }

    private static func measureCuts(pose: PoseEstimate, image: BinaryImage, spec: KeySpec) throws -> [CutMeasurement] {
        var cuts: [CutMeasurement] = []
        // The window is about half of the 0.031 in root flat, centered on the station,
        // so the minimum is the flat and not the cutter wall.
        let halfWindow = spec.rootFlatInches / 4 * pose.pixelsPerInch
        for (offset, station) in spec.usedStationsInches.enumerated() {
            let axial = station * pose.pixelsPerInch
            var samples: [Double] = []
            var cursor = -halfWindow
            while cursor <= halfWindow + 1e-6 {
                if let distance = topDistance(
                    axial: axial + cursor,
                    origin: pose.origin,
                    direction: pose.tipDirection,
                    normal: pose.bittingDirection,
                    image: image,
                    limit: pose.bladeLengthPixels
                ) {
                    samples.append(distance)
                }
                cursor += 0.5
            }
            guard let rootPixels = stableMinimum(samples) else { throw KeyMeasurementError.bladeNotFound }
            let rootInches = rootPixels / pose.pixelsPerInch
            let bite = KeyMath.nearestBite(rootInches: rootInches, spec: spec)
            let rootMillimeters = KeyMath.millimeters(fromInches: rootInches)
            let shoulderMillimeters = KeyMath.millimeters(fromInches: station)
            let bottom = pose.origin + pose.tipDirection * axial
            let rootPoint = bottom + pose.bittingDirection * rootPixels
            cuts.append(CutMeasurement(
                index: offset + 1,
                shoulderInches: station,
                shoulderMillimeters: shoulderMillimeters,
                rootInches: rootInches,
                rootMillimeters: rootMillimeters,
                nearestBite: bite,
                deviationMillimeters: KeyMath.deviationMillimeters(measuredRootInches: rootInches, bite: bite, spec: spec),
                outsideTolerance: KeyMath.outsideTolerance(measuredRootInches: rootInches, bite: bite, spec: spec),
                rootPoint: rootPoint,
                bottomPoint: bottom
            ))
        }
        return cuts
    }

    /// Minimum bottom-distance, ignoring isolated pixels that fall through the silhouette.
    private static func stableMinimum(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let surface = samples.filter { $0 >= median - 1.5 }
        return surface.min() ?? median
    }

    /// Distance from the fitted blade-bottom line to the bitting edge, in pixels.
    private static func topDistance(
        axial: Double,
        origin: Point2D,
        direction: Point2D,
        normal: Point2D,
        image: BinaryImage,
        limit: Double
    ) -> Double? {
        let base = origin + direction * axial
        let step = 0.25
        var s = -6.0
        var seenInside = false
        var lastInside = 0.0
        let scanLimit = max(limit * 0.8, 24)
        while s < scanLimit {
            let point = base + normal * s
            if image.contains(point) {
                seenInside = true
                lastInside = s
            } else if seenInside {
                return lastInside + step * 0.5
            }
            s += step
        }
        return nil
    }

    private static func interiorScore(_ normal: Point2D, shoulder: Point2D, tip: Point2D, image: BinaryImage) -> Int {
        let direction = (tip - shoulder).unit()
        let length = (tip - shoulder).length
        var score = 0
        for index in 2..<12 {
            let t = length * Double(index) / 12
            let probe = shoulder + direction * t + normal * 6
            if image.contains(probe) { score += 1 }
        }
        return score
    }

    private static func massBeyond(_ end: Point2D, awayFrom other: Point2D, image: BinaryImage) -> Int {
        let outward = (end - other).unit()
        var count = 0
        let stride = 2
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                if image.contains(x: x, y: y) {
                    let delta = Point2D(x: Double(x) + 0.5, y: Double(y) + 0.5) - end
                    if delta.dot(outward) > 3 {
                        count += 1
                    }
                }
                x += stride
            }
            y += stride
        }
        return count
    }

    private static func longestStraightRun(_ points: [Point2D]) -> [Point2D]? {
        let count = points.count
        guard count > 30 else { return nil }
        let ring = points + points
        let tolerance = 1.85
        var bestStart = 0
        var bestSpan = 0
        var bestLength = 0.0
        var start = 0
        while start < count {
            var low = start + 10
            var high = start + count - 1
            var far = start
            while low <= high {
                let mid = (low + high) / 2
                if maxChordDeviation(ring, from: start, to: mid) <= tolerance {
                    far = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            let span = far - start
            if span > bestSpan {
                let length = (ring[far] - ring[start]).length
                if length > bestLength {
                    bestLength = length
                    bestStart = start
                    bestSpan = span
                }
            } else if span > 10 {
                let length = (ring[far] - ring[start]).length
                if length > bestLength {
                    bestLength = length
                    bestStart = start
                    bestSpan = span
                }
            }
            start += 3
        }
        guard bestSpan > 20, bestLength > 15 else { return nil }
        return (0...bestSpan).map { ring[bestStart + $0] }
    }

    private static func maxChordDeviation(_ ring: [Point2D], from start: Int, to end: Int) -> Double {
        let a = ring[start]
        let b = ring[end]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        if length < 1e-6 { return 0 }
        let span = end - start
        let samples = min(span, 28)
        if samples <= 1 { return 0 }
        var maxDistance = 0.0
        for sample in 0...samples {
            let index = start + (span * sample) / samples
            let point = ring[index]
            let distance = abs((point.x - a.x) * dy - (point.y - a.y) * dx) / length
            if distance > maxDistance { maxDistance = distance }
        }
        return maxDistance
    }

    /// Largest foreground component that does not touch the image border. That is the key on a contrasting field.
    static func largestInteriorBlob(_ image: BinaryImage) -> BinaryImage? {
        let count = image.width * image.height
        var seen = [Bool](repeating: false, count: count)
        var bestPixels: [Int] = []
        var stack: [Int] = []
        stack.reserveCapacity(1024)

        for row in 0..<image.height {
            for column in 0..<image.width {
                let start = image.index(column, row)
                if seen[start] || !image.pixels[start] { continue }
                stack.removeAll(keepingCapacity: true)
                stack.append(start)
                seen[start] = true
                var pixels: [Int] = []
                var touchesBorder = false
                while let current = stack.popLast() {
                    let x = current % image.width
                    let y = current / image.width
                    pixels.append(current)
                    if x == 0 || y == 0 || x == image.width - 1 || y == image.height - 1 {
                        touchesBorder = true
                    }
                    let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                    for (nx, ny) in neighbors {
                        guard nx >= 0, ny >= 0, nx < image.width, ny < image.height else { continue }
                        let next = image.index(nx, ny)
                        if seen[next] || !image.pixels[next] { continue }
                        seen[next] = true
                        stack.append(next)
                    }
                }
                if !touchesBorder && pixels.count > bestPixels.count {
                    bestPixels = pixels
                }
            }
        }
        guard bestPixels.count > 80 else { return nil }
        var pixels = [Bool](repeating: false, count: count)
        for index in bestPixels {
            pixels[index] = true
        }
        return BinaryImage(width: image.width, height: image.height, pixels: pixels)
    }
}

enum ContourTracer {
    /// Clockwise 8-neighborhood starting at north.
    private static let neighbors = [
        (0, -1), (1, -1), (1, 0), (1, 1),
        (0, 1), (-1, 1), (-1, 0), (-1, -1),
    ]

    static func trace(_ image: BinaryImage) -> [Point2D] {
        guard let start = firstForeground(image) else { return [] }
        let neighborCount = neighbors.count
        var points: [Point2D] = []
        var current = start
        var entryDirection = 0
        let limit = image.width * image.height
        var steps = 0
        repeat {
            points.append(Point2D(x: Double(current.0) + 0.5, y: Double(current.1) + 0.5))
            let begin = (entryDirection + 1) % neighborCount
            var nextPixel: (Int, Int)?
            var nextDirection = 0
            for offset in 0..<neighborCount {
                let direction = (begin + offset) % neighborCount
                let nx = current.0 + neighbors[direction].0
                let ny = current.1 + neighbors[direction].1
                if image.contains(x: nx, y: ny) {
                    nextPixel = (nx, ny)
                    nextDirection = direction
                    break
                }
            }
            guard let nextPixel else { break }
            entryDirection = (nextDirection + 4) % neighborCount
            current = nextPixel
            steps += 1
            if steps > limit { break }
        } while current != start
        return points
    }

    private static func firstForeground(_ image: BinaryImage) -> (Int, Int)? {
        for y in 0..<image.height {
            for x in 0..<image.width where image.contains(x: x, y: y) {
                return (x, y)
            }
        }
        return nil
    }
}
