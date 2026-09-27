import Foundation

/// Step-through of one placed key. Shoulder on the left, blade to the right, bites up.
public struct BladeScan: Equatable, Sendable {
    /// Clockwise degrees applied to level the blade bottom. Zero means it was already horizontal.
    public let levelingDegrees: Double
    public let shoulder: Point2D
    /// Point on the detected bottom edge nearest the crosshair.
    public let bottomStart: Point2D
    public let bottomEnd: Point2D
    /// Signed pixels from the crosshair to the bottom edge. Positive means the edge is above the crosshair, toward the cuts.
    public let bottomOffsetPixels: Double
    /// Five cut roots, in the order they were found, shoulder toward the tip.
    public let minima: [Point2D]
    /// The same five roots moved onto equal spacing.
    public let equalized: [Point2D]
    public let spacingPixels: Double
    public let pixelDepths: [Double]
    public let bites: [Int]
    public let code: String
    /// Top of the blade, decimated, in image pixels.
    public let edge: [Point2D]

    public static let cutSpacingInches = 0.156
    public static let stepCount = 10

    public func caption(for step: Int) -> String {
        switch step {
        case 0:
            return "Step 1. The key at the shoulder mark, lifted from the background."
        case 1:
            let tilt = -levelingDegrees
            let place = bottomOffsetPixels >= 0 ? "above" : "below"
            return String(
                format: "Step 2. Bottom edge is %+.1f° from horizontal, %.0f px %@ the crosshair.",
                tilt,
                abs(bottomOffsetPixels),
                place
            )
        case 2...6:
            return "Step 3. Minimum \(step - 1) of 5, moving right from the shoulder."
        case 7:
            return String(format: "Step 4. The five minima are spaced equally, %.3f in apart.", Self.cutSpacingInches)
        case 8:
            return "Step 5. Pixel depths from the blade bottom, matched by ratio to the SC1 table."
        default:
            return "Step 6. Bitting code \(code)."
        }
    }

    /// How many minima to draw at this step. The lift and level steps draw none.
    public func revealedMinimumCount(at step: Int) -> Int {
        if step <= 1 { return 0 }
        if step >= 7 { return minima.count }
        return min(step - 1, minima.count)
    }
}

/// A scan, plus the edge pixels from the bottom-edge step. Edges are present even when the scan stops early.
public struct BladeScanAttempt: Equatable, Sendable {
    public var scan: BladeScan?
    public var foundEdges: [Point2D]
    public var selectedEdges: [Point2D]

    public init(scan: BladeScan?, foundEdges: [Point2D], selectedEdges: [Point2D]) {
        self.scan = scan
        self.foundEdges = foundEdges
        self.selectedEdges = selectedEdges
    }

    public static let empty = BladeScanAttempt(scan: nil, foundEdges: [], selectedEdges: [])
}

public enum BladeScanner {
    /// Levels the blade from its bottom edge, finds five cut roots, spaces them equally, and matches depth ratios to the bite table.
    public static func scan(
        boundary points: [Point2D],
        shoulder: Point2D,
        spec: KeySpec,
        search: BladeBottomSearch
    ) -> BladeScanAttempt {
        let located = BladeScanAttempt(scan: nil, foundEdges: search.edges, selectedEdges: search.selected)
        guard points.count >= 80, spec.cutCount == 5, spec.rootDepthsInches.count >= 10 else { return located }
        guard let bottom = search.bottom else { return located }
        let leveled = level(points, shoulder: shoulder, bottom: bottom)
        let columns = profile(leveled.samples)
        guard columns.count > 30 else { return located }
        guard let valleys = fiveValleys(in: columns) else { return located }
        let spacing = (valleys[4].along - valleys[0].along) / 4
        guard spacing > 4 else { return located }
        let stations = (0..<5).map { valleys[0].along + Double($0) * spacing }
        let depths = stations.map { height(at: $0, columns: columns) }
        guard depths.allSatisfy({ $0 > 4 }), let bites = bites(matching: depths, spec: spec) else { return located }
        let edge = stride(from: 0, to: columns.count, by: max(1, columns.count / 180)).map { index in
            leveled.image(columns[index].along, columns[index].height)
        }
        let scan = BladeScan(
            levelingDegrees: leveled.correctionDegrees,
            shoulder: shoulder,
            bottomStart: leveled.image(0, 0),
            bottomEnd: leveled.image(max(leveled.bottomSpan, columns[columns.count - 1].along), 0),
            bottomOffsetPixels: leveled.bottomOffset,
            minima: valleys.map { leveled.image($0.along, $0.height) },
            equalized: zip(stations, depths).map { leveled.image($0.0, $0.1) },
            spacingPixels: spacing,
            pixelDepths: depths,
            bites: bites,
            code: bites.map(String.init).joined(),
            edge: edge
        )
        return BladeScanAttempt(scan: scan, foundEdges: search.edges, selectedEdges: search.selected)
    }

    /// Bite numbers whose spec depths are in the same ratios as the pixel depths.
    public static func bites(matching pixelDepths: [Double], spec: KeySpec) -> [Int]? {
        guard pixelDepths.count == spec.cutCount, pixelDepths.allSatisfy({ $0 > 0 }) else { return nil }
        let table = spec.rootDepthsInches
        var bestError = Double.greatestFiniteMagnitude
        var best: [Int] = []
        var choice = [Int](repeating: 0, count: pixelDepths.count)
        func search(_ index: Int) {
            if index == pixelDepths.count {
                var scales: [Double] = []
                scales.reserveCapacity(pixelDepths.count)
                for cut in 0..<pixelDepths.count {
                    scales.append(pixelDepths[cut] / table[choice[cut]])
                }
                let mean = scales.reduce(0, +) / Double(scales.count)
                var error = 0.0
                for scale in scales {
                    let delta = (scale - mean) / mean
                    error += delta * delta
                }
                if error < bestError - 1e-12 || (abs(error - bestError) <= 1e-12 && choice.lexicographicallyPrecedes(best)) {
                    bestError = error
                    best = choice
                }
                return
            }
            for bite in 0..<table.count {
                choice[index] = bite
                search(index + 1)
            }
        }
        search(0)
        return best.count == pixelDepths.count ? best : nil
    }
}

private struct LeveledBlade {
    var samples: [LocalPoint]
    /// Degrees added to the image so the blade bottom lies on +X. Opposite of the bottom's tilt.
    var correctionDegrees: Double
    var bottomOffset: Double
    var bottomSpan: Double
    var image: (Double, Double) -> Point2D
}

private struct LocalPoint {
    var along: Double
    var height: Double
}

private struct Column {
    var along: Double
    var height: Double
}

private struct Valley {
    var along: Double
    var height: Double
}

private func level(_ points: [Point2D], shoulder: Point2D, bottom: BladeBottom) -> LeveledBlade {
    let radians = bottom.angleDegrees * .pi / 180
    let cosine = cos(radians)
    let sine = sin(radians)
    let offset = bottom.offsetPixels
    let samples = points.map { point -> LocalPoint in
        let dx = point.x - shoulder.x
        let dy = point.y - shoulder.y
        return LocalPoint(
            along: dx * cosine + dy * sine,
            height: dx * sine - dy * cosine - offset
        )
    }
    let image: (Double, Double) -> Point2D = { along, heightAboveBottom in
        let raw = heightAboveBottom + offset
        return Point2D(
            shoulder.x + along * cosine + raw * sine,
            shoulder.y + along * sine - raw * cosine
        )
    }
    return LeveledBlade(
        samples: samples,
        correctionDegrees: -bottom.angleDegrees,
        bottomOffset: offset,
        bottomSpan: bottom.spanPixels,
        image: image
    )
}

private func profile(_ samples: [LocalPoint]) -> [Column] {
    let blade = samples.filter { $0.along > 0 && $0.height > -4 }
    guard let maxAlong = blade.map(\.along).max(), maxAlong > 30 else { return [] }
    let limit = Int(maxAlong)
    var bins = [Double](repeating: 0, count: limit + 1)
    var seen = [Bool](repeating: false, count: limit + 1)
    for sample in blade {
        let index = min(limit, max(0, Int(sample.along)))
        bins[index] = max(bins[index], sample.height)
        seen[index] = true
    }
    var columns: [Column] = []
    var carry = 0.0
    var gap = 0
    for index in 1...limit {
        if seen[index], bins[index] > 2 {
            carry = bins[index]
            gap = 0
            columns.append(Column(along: Double(index) + 0.5, height: bins[index]))
        } else if gap < 8, carry > 2 {
            gap += 1
            columns.append(Column(along: Double(index) + 0.5, height: carry))
        } else {
            gap += 1
            if gap > 8 {
                carry = 0
            }
        }
    }
    return columns
}

private func fiveValleys(in columns: [Column]) -> [Valley]? {
    guard let crest = bladeCrest(columns), crest > 8, columns.count > 20 else { return nil }
    let smoothed = smooth(columns.map(\.height))
    let rise = max(1.5, crest * 0.012)
    let exit = 0.35
    var valleys: [Valley] = []
    var peak = smoothed[0]
    var low = smoothed[0]
    var lowStart = 0
    var lowEnd = 0
    for index in 1..<smoothed.count {
        let height = smoothed[index]
        if height >= low + exit, peak - low >= rise {
            let middle = (lowStart + lowEnd) / 2
            let depth = columns[middle].height
            if depth > crest * 0.45 {
                valleys.append(Valley(along: columns[middle].along, height: depth))
            }
            peak = height
            low = height
            lowStart = index
            lowEnd = index
        } else if height < low {
            low = height
            lowStart = index
            lowEnd = index
        } else if height <= low + exit {
            lowEnd = index
        } else if height > peak {
            peak = height
            low = height
            lowStart = index
            lowEnd = index
        }
    }
    return chooseFive(valleys)
}

private func smooth(_ values: [Double]) -> [Double] {
    let radius = max(2, values.count / 80)
    return values.indices.map { index in
        let low = max(0, index - radius)
        let high = min(values.count - 1, index + radius)
        var total = 0.0
        for sample in low...high {
            total += values[sample]
        }
        return total / Double(high - low + 1)
    }
}

private func bladeCrest(_ columns: [Column]) -> Double? {
    guard let last = columns.last else { return nil }
    let early = columns.filter { $0.along > 2 && $0.along < last.along * 0.12 }
    let pool = early.isEmpty ? columns : early
    let sorted = pool.map(\.height).sorted()
    guard !sorted.isEmpty else { return nil }
    return sorted[sorted.count * 9 / 10]
}

private func chooseFive(_ valleys: [Valley]) -> [Valley]? {
    let ordered = valleys.sorted { $0.along < $1.along }
    if ordered.count == 5 { return ordered }
    if ordered.count < 5 { return nil }
    let pool = ordered.count > 12 ? Array(ordered.sorted { $0.height < $1.height }.prefix(12)).sorted { $0.along < $1.along } : ordered
    var best: [Valley]?
    var bestScore = Double.greatestFiniteMagnitude
    for subset in combinations(pool, count: 5) {
        let gaps = (1..<subset.count).map { subset[$0].along - subset[$0 - 1].along }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        guard mean > 4 else { continue }
        var variance = 0.0
        for gap in gaps {
            let delta = (gap - mean) / mean
            variance += delta * delta
        }
        if variance < bestScore {
            bestScore = variance
            best = subset
        }
    }
    return best
}

private func combinations<T>(_ values: [T], count: Int) -> [[T]] {
    if count == 0 { return [[]] }
    if values.count < count { return [] }
    if values.count == count { return [values] }
    let head = values[0]
    let tail = Array(values.dropFirst())
    let withHead = combinations(tail, count: count - 1).map { [head] + $0 }
    return withHead + combinations(tail, count: count)
}

private func height(at along: Double, columns: [Column]) -> Double {
    guard let first = columns.first, let last = columns.last else { return .nan }
    if along <= first.along { return first.height }
    if along >= last.along { return last.height }
    for index in 1..<columns.count where columns[index].along >= along {
        let left = columns[index - 1]
        let right = columns[index]
        let span = right.along - left.along
        guard span > 0 else { return right.height }
        let t = (along - left.along) / span
        return left.height + (right.height - left.height) * t
    }
    return last.height
}
