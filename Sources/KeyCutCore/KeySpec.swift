import Foundation

public struct KeySpec: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    /// Shoulder-to-cut-center distances in inches, bow to tip. May include stations this key does not cut.
    public let stationsInches: [Double]
    /// How many leading stations this key uses. SC1 uses the first five of six chart stations.
    public let cutCount: Int
    /// Root depth from the blade bottom, bite 0 through 9, in inches.
    public let rootDepthsInches: [Double]
    public let depthIncrementInches: Double
    /// Full uncut blade height, bottom to top, in inches. Scale reference.
    public let bladeHeightInches: Double
    public let includedAngleDegrees: Double
    public let rootFlatInches: Double
    public let macs: Int
    /// Measured root may be this much larger than nominal. A larger root depth is a shallower cut.
    public let depthTolerancePlusInches: Double
    /// Measured root may be this much smaller than nominal. A smaller root depth is a deeper cut.
    public let depthToleranceMinusInches: Double
    /// Absolute deviation above the tolerance and at or below this value is a caution, not a failure.
    public let depthCautionInches: Double
    public let spacingToleranceInches: Double

    public init(
        id: String,
        displayName: String,
        stationsInches: [Double],
        cutCount: Int,
        rootDepthsInches: [Double],
        depthIncrementInches: Double,
        bladeHeightInches: Double,
        includedAngleDegrees: Double,
        rootFlatInches: Double,
        macs: Int,
        depthTolerancePlusInches: Double,
        depthToleranceMinusInches: Double,
        depthCautionInches: Double,
        spacingToleranceInches: Double
    ) {
        self.id = id
        self.displayName = displayName
        self.stationsInches = stationsInches
        self.cutCount = cutCount
        self.rootDepthsInches = rootDepthsInches
        self.depthIncrementInches = depthIncrementInches
        self.bladeHeightInches = bladeHeightInches
        self.includedAngleDegrees = includedAngleDegrees
        self.rootFlatInches = rootFlatInches
        self.macs = macs
        self.depthTolerancePlusInches = depthTolerancePlusInches
        self.depthToleranceMinusInches = depthToleranceMinusInches
        self.depthCautionInches = depthCautionInches
        self.spacingToleranceInches = spacingToleranceInches
    }

    public var usedStationsInches: [Double] {
        Array(stationsInches.prefix(cutCount))
    }

    /// Half-width of the sampling window around a cut station, inside the root flat.
    public var rootWindowHalfWidthInches: Double {
        min(0.012, rootFlatInches * 0.40)
    }

    public func rootDepthInches(bite: Int) -> Double {
        rootDepthsInches[bite]
    }

    public func rootDepthMillimeters(bite: Int) -> Double {
        Units.millimeters(fromInches: rootDepthsInches[bite])
    }

    public func stationMillimeters(cutIndex: Int) -> Double {
        Units.millimeters(fromInches: usedStationsInches[cutIndex])
    }
}

/// Face dimensions of one key blank. Lengths are along the blade; widths are across the head and blade.
public struct KeyBlank: Equatable, Sendable {
    public let overallMillimeters: Double
    public let bowWidthMillimeters: Double
    public let bladeLengthMillimeters: Double
    public let bladeWidthMillimeters: Double

    public init(
        overallMillimeters: Double,
        bowWidthMillimeters: Double,
        bladeLengthMillimeters: Double,
        bladeWidthMillimeters: Double
    ) {
        self.overallMillimeters = overallMillimeters
        self.bowWidthMillimeters = bowWidthMillimeters
        self.bladeLengthMillimeters = bladeLengthMillimeters
        self.bladeWidthMillimeters = bladeWidthMillimeters
    }

    public var overallInches: Double { overallMillimeters / 25.4 }
    public var bowWidthInches: Double { bowWidthMillimeters / 25.4 }
    public var bladeLengthInches: Double { bladeLengthMillimeters / 25.4 }
    public var bladeWidthInches: Double { bladeWidthMillimeters / 25.4 }
    public var bowLengthInches: Double { (overallMillimeters - bladeLengthMillimeters) / 25.4 }
    /// Bow metal past each edge of the blade. The head is wider than the blade on both sides.
    public var bowSideInches: Double { (bowWidthInches - bladeWidthInches) / 2 }
    /// Bitting-side top of the bow, measured from the blade spine.
    public var bowTopInches: Double { bladeWidthInches + bowSideInches }
    /// Spine-side bottom of the bow, below the blade spine.
    public var bowBottomInches: Double { -bowSideInches }
    /// Tip chamfer begins this far from the shoulder. Taken from the drawing's tip, not a separate callout.
    public var tipTaperStartInches: Double { bladeLengthInches - (3.8 / 25.4) }
}

public enum KeyBlanks {
    /// Standard SC1 blank: 52.9 mm overall, 26.5 mm head, 26.15 mm blade, 8.85 mm blade width.
    public static let sc1 = KeyBlank(
        overallMillimeters: 52.9,
        bowWidthMillimeters: 26.5,
        bladeLengthMillimeters: 26.15,
        bladeWidthMillimeters: 8.85
    )
}

public enum KeyCatalog {
    public static let sc1 = KeySpec(
        id: "SC1",
        displayName: "Schlage SC1",
        stationsInches: [0.231, 0.3872, 0.5434, 0.6996, 0.8558, 1.012],
        cutCount: 5,
        rootDepthsInches: [0.335, 0.320, 0.305, 0.290, 0.275, 0.260, 0.245, 0.230, 0.215, 0.200],
        depthIncrementInches: 0.015,
        bladeHeightInches: 0.343,
        includedAngleDegrees: 100,
        rootFlatInches: 0.031,
        macs: 7,
        depthTolerancePlusInches: 0.002,
        depthToleranceMinusInches: 0.002,
        depthCautionInches: 0.005,
        spacingToleranceInches: 0.001
    )

    public static let all: [KeySpec] = [sc1]

    public static func spec(id: String) -> KeySpec? {
        all.first { $0.id == id }
    }
}

public enum DepthBand: Equatable, Sendable {
    /// Within the depth tolerance.
    case nominal
    /// Outside tolerance, at or inside the caution limit.
    case caution
    /// Beyond the caution limit.
    case fail
}

public struct BiteMatch: Equatable, Sendable {
    public let bite: Int
    public let deviationInches: Double
    public let deviationMillimeters: Double
    public let outsideTolerance: Bool
}

public struct MACSViolation: Equatable, Sendable {
    /// 1-based cut numbers, bow to tip.
    public let leftCut: Int
    public let rightCut: Int
    public let difference: Int
}

public enum BittingMath {
    /// Nearest of the ten root depths. A tie keeps the lower bite number.
    public static func nearestBite(rootDepthInches: Double, spec: KeySpec) -> BiteMatch {
        var bestBite = 0
        var bestDistance = abs(rootDepthInches - spec.rootDepthsInches[0])
        for bite in 1..<spec.rootDepthsInches.count {
            let distance = abs(rootDepthInches - spec.rootDepthsInches[bite])
            if distance < bestDistance {
                bestDistance = distance
                bestBite = bite
            }
        }
        let deviationInches = rootDepthInches - spec.rootDepthsInches[bestBite]
        let positiveExcess = deviationInches - spec.depthTolerancePlusInches
        let negativeExcess = -deviationInches - spec.depthToleranceMinusInches
        let outside = positiveExcess > 1e-9 || negativeExcess > 1e-9
        return BiteMatch(
            bite: bestBite,
            deviationInches: deviationInches,
            deviationMillimeters: Units.millimeters(fromInches: deviationInches),
            outsideTolerance: outside
        )
    }

    /// White within ±tolerance, yellow through the caution limit, red beyond it.
    public static func depthBand(deviationInches: Double, spec: KeySpec) -> DepthBand {
        let magnitude = abs(deviationInches)
        let tolerance = max(spec.depthTolerancePlusInches, spec.depthToleranceMinusInches)
        if magnitude <= tolerance + 1e-9 { return .nominal }
        if magnitude <= spec.depthCautionInches + 1e-9 { return .caution }
        return .fail
    }

    public static func macsViolations(bites: [Int], spec: KeySpec) -> [MACSViolation] {
        guard bites.count >= 2 else { return [] }
        var violations: [MACSViolation] = []
        for index in 0..<(bites.count - 1) {
            let difference = abs(bites[index] - bites[index + 1])
            if difference > spec.macs {
                violations.append(MACSViolation(leftCut: index + 1, rightCut: index + 2, difference: difference))
            }
        }
        return violations
    }

    public static func macsWarning(violations: [MACSViolation], spec: KeySpec) -> String? {
        guard let first = violations.first else { return nil }
        if violations.count == 1 {
            return "MACS \(spec.macs): cuts \(first.leftCut) and \(first.rightCut) differ by \(first.difference)"
        }
        return "MACS \(spec.macs): adjacent cuts differ by more than \(spec.macs)"
    }
}
