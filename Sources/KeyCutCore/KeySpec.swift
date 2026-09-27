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
    /// Depth may be this much deeper (larger root-depth number) than nominal.
    public let depthTolerancePlusInches: Double
    /// Depth may be this much shallower (smaller root-depth number) than nominal.
    public let depthToleranceMinusInches: Double
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
        depthToleranceMinusInches: 0,
        spacingToleranceInches: 0.001
    )

    public static let all: [KeySpec] = [sc1]

    public static func spec(id: String) -> KeySpec? {
        all.first { $0.id == id }
    }
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
