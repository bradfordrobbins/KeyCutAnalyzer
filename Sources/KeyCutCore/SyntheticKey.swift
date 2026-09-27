import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct SyntheticPose: Equatable, Sendable {
    public var rotationRadians: Double
    public var pixelsPerInch: Double
    /// When true, the bitting is mirrored across the blade bottom before rotation.
    public var reflectBitting: Bool

    public init(rotationRadians: Double, pixelsPerInch: Double, reflectBitting: Bool) {
        self.rotationRadians = rotationRadians
        self.pixelsPerInch = pixelsPerInch
        self.reflectBitting = reflectBitting
    }

    public static func identity(pixelsPerInch: Double) -> SyntheticPose {
        SyntheticPose(rotationRadians: 0, pixelsPerInch: pixelsPerInch, reflectBitting: false)
    }
}

public enum SyntheticKey {
    public static var bowLengthInches: Double { KeyBlanks.sc1.bowLengthInches }
    public static var bowHeightInches: Double { KeyBlanks.sc1.bowTopInches }
    public static var tipInches: Double { KeyBlanks.sc1.bladeLengthInches }
    public static var tipTaperStartInches: Double { KeyBlanks.sc1.tipTaperStartInches }
    /// Bow back to tip.
    public static var spanInches: Double { KeyBlanks.sc1.overallInches }

    /// Uncut SC1 blank in key inches. Shoulder at the origin, tip toward +X, bitting toward +Y.
    /// The bow is wider than the blade on both sides of the spine. Screen placement turns +X to the left.
    public static func blankOutline() -> [Point2D] {
        let blank = KeyBlanks.sc1
        let blade = blank.bladeWidthInches
        let tip = blank.bladeLengthInches
        let bow = blank.bowLengthInches
        let top = blank.bowTopInches
        let bottom = blank.bowBottomInches
        let taperStart = blank.tipTaperStartInches
        let neck = 2.2 / 25.4
        let step = 4.8 / 25.4
        let tab = 7.2 / 25.4
        let mid = blade / 2
        let tabHalf = blank.bowWidthInches * 0.20
        return [
            Point2D(tip, 0),
            Point2D(taperStart, blade),
            Point2D(0, blade),
            Point2D(-neck, blade),
            Point2D(-neck, top * 0.62),
            Point2D(-step, top),
            Point2D(-(bow - tab), top),
            Point2D(-(bow - tab * 0.45), mid + tabHalf),
            Point2D(-bow, mid + tabHalf * 0.55),
            Point2D(-bow, mid - tabHalf * 0.55),
            Point2D(-(bow - tab * 0.45), mid - tabHalf),
            Point2D(-(bow - tab), bottom),
            Point2D(-step, bottom),
            Point2D(-neck, bottom * 0.35),
            Point2D(-neck, 0),
            Point2D(0, 0)
        ]
    }

    /// Pose of the blank in a crop of its bounding box. Head on the right, blade to the left, bites up.
    public static func blankPose(cropWidth: Double, cropHeight: Double) -> KeyPose {
        let blank = KeyBlanks.sc1
        let span = blank.overallInches
        let height = blank.bowWidthInches
        let pixelsPerInch = cropWidth / span
        return KeyPose(
            origin: Point2D(
                cropWidth * (blank.bladeLengthInches / span),
                cropHeight * (blank.bowTopInches / height)
            ),
            tipAxis: Point2D(-1, 0),
            bittingAxis: Point2D(0, -1),
            pixelsPerInch: pixelsPerInch
        )
    }

    public static func contour(code: [Int], spec: KeySpec) -> [Point2D] {
        let bites = normalized(code: code, spec: spec)
        let samples = sampleAbscissae(bites: bites, spec: spec)
        var polygon: [Point2D] = [
            Point2D(-bowLengthInches, 0),
            Point2D(tipInches, 0)
        ]
        for x in samples.reversed() {
            polygon.append(Point2D(x, topHeight(at: x, bites: bites, spec: spec)))
        }
        polygon.append(Point2D(0, bowHeightInches))
        polygon.append(Point2D(-bowLengthInches, bowHeightInches))
        return polygon
    }

    public static func raster(code: [Int], spec: KeySpec, pose: SyntheticPose, margin: Double = 24) -> BinaryRaster {
        let polygon = contour(code: code, spec: spec).map { imagePoint($0, pose: pose) }
        let minX = polygon.map(\.x).min() ?? 0
        let minY = polygon.map(\.y).min() ?? 0
        let maxX = polygon.map(\.x).max() ?? 0
        let maxY = polygon.map(\.y).max() ?? 0
        let shifted = polygon.map { Point2D($0.x - minX + margin, $0.y - minY + margin) }
        let width = Int(ceil(maxX - minX + margin * 2)) + 2
        let height = Int(ceil(maxY - minY + margin * 2)) + 2
        return Rasterizer.fill(polygon: shifted, width: width, height: height)
    }

    static func topHeight(at x: Double, bites: [Int], spec: KeySpec) -> Double {
        if x >= tipInches { return 0 }
        if x >= tipTaperStartInches {
            let base = cutLimitedHeight(at: tipTaperStartInches, bites: bites, spec: spec)
            let span = tipInches - tipTaperStartInches
            let t = span > 0 ? (x - tipTaperStartInches) / span : 1
            return base * (1 - t)
        }
        return cutLimitedHeight(at: x, bites: bites, spec: spec)
    }

    private static func cutLimitedHeight(at x: Double, bites: [Int], spec: KeySpec) -> Double {
        let blade = spec.bladeHeightInches
        let flatHalf = spec.rootFlatInches / 2
        let wallFromVertical = (180 - spec.includedAngleDegrees) / 2
        let tanWall = tan(wallFromVertical * .pi / 180)
        var height = blade
        let stations = spec.usedStationsInches
        for index in 0..<bites.count {
            let depth = spec.rootDepthsInches[bites[index]]
            let center = stations[index]
            let rise = blade - depth
            guard rise > 0, tanWall > 1e-9 else {
                if abs(x - center) <= flatHalf {
                    height = min(height, depth)
                }
                continue
            }
            let run = rise * tanWall
            let left = center - flatHalf
            let right = center + flatHalf
            let cutHeight: Double
            if x >= left && x <= right {
                cutHeight = depth
            } else if x < left {
                let dx = left - x
                if dx >= run { continue }
                cutHeight = depth + dx / tanWall
            } else {
                let dx = x - right
                if dx >= run { continue }
                cutHeight = depth + dx / tanWall
            }
            height = min(height, cutHeight)
        }
        return height
    }

    private static func sampleAbscissae(bites: [Int], spec: KeySpec) -> [Double] {
        var values: [Double] = [0, tipTaperStartInches, tipInches]
        let flatHalf = spec.rootFlatInches / 2
        let wallFromVertical = (180 - spec.includedAngleDegrees) / 2
        let tanWall = tan(wallFromVertical * .pi / 180)
        let stations = spec.usedStationsInches
        for index in 0..<bites.count {
            let depth = spec.rootDepthsInches[bites[index]]
            let center = stations[index]
            let run = max(0, (spec.bladeHeightInches - depth) * tanWall)
            values.append(contentsOf: [
                center - flatHalf - run,
                center - flatHalf,
                center,
                center + flatHalf,
                center + flatHalf + run
            ])
        }
        var x = 0.0
        while x < tipInches {
            values.append(x)
            x += 0.004
        }
        let clipped = values.map { min(max($0, 0), tipInches) }.sorted()
        var unique: [Double] = []
        for value in clipped {
            if let last = unique.last, abs(value - last) < 1e-6 { continue }
            unique.append(value)
        }
        return unique
    }

    private static func normalized(code: [Int], spec: KeySpec) -> [Int] {
        (0..<spec.cutCount).map { index in
            let bite = index < code.count ? code[index] : 0
            return min(max(bite, 0), spec.rootDepthsInches.count - 1)
        }
    }

    private static func imagePoint(_ keyPoint: Point2D, pose: SyntheticPose) -> Point2D {
        let x = keyPoint.x
        let y = pose.reflectBitting ? -keyPoint.y : keyPoint.y
        let cosine = cos(pose.rotationRadians)
        let sine = sin(pose.rotationRadians)
        let worldX = pose.pixelsPerInch * (cosine * x - sine * y)
        let worldY = pose.pixelsPerInch * (sine * x + cosine * y)
        return Point2D(worldX, -worldY)
    }
}
