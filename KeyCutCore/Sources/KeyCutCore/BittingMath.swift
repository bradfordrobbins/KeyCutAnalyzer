import Foundation

public enum KeyMath {
    public static let millimetersPerInch = 25.4

    public static func millimeters(fromInches inches: Double) -> Double {
        inches * millimetersPerInch
    }

    public static func formatMillimeters(_ millimeters: Double) -> String {
        String(format: "%.3f", millimeters)
    }

    public static func formatInchesAsMillimeters(_ inches: Double) -> String {
        formatMillimeters(millimeters(fromInches: inches))
    }

    /// Nearest charted bite. An exact halfway root belongs to the lower bite number.
    public static func nearestBite(rootInches: Double, spec: KeySpec) -> Int {
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, depth) in spec.rootDepthsInches.enumerated() {
            let distance = abs(rootInches - depth)
            if distance < bestDistance - 1e-12 {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    public static func deviationMillimeters(measuredRootInches: Double, bite: Int, spec: KeySpec) -> Double {
        let specMillimeters = millimeters(fromInches: spec.rootDepthsInches[bite])
        let measuredMillimeters = millimeters(fromInches: measuredRootInches)
        return measuredMillimeters - specMillimeters
    }

    /// Charted root tolerance is +.002 in / −0 on the root depth (distance from the blade bottom).
    public static func outsideTolerance(measuredRootInches: Double, bite: Int, spec: KeySpec) -> Bool {
        let delta = measuredRootInches - spec.rootDepthsInches[bite]
        let epsilon = 1e-6
        if delta > spec.rootTolerancePlusInches + epsilon { return true }
        if delta < -spec.rootToleranceMinusInches - epsilon { return true }
        return false
    }

    /// Pair indexes (the bow-side cut of each pair) whose bite numbers differ by more than MACS.
    public static func macsViolatingPairs(bites: [Int], spec: KeySpec) -> [Int] {
        guard bites.count >= 2 else { return [] }
        var pairs: [Int] = []
        for index in 0..<(bites.count - 1) {
            if abs(bites[index] - bites[index + 1]) > spec.macs {
                pairs.append(index)
            }
        }
        return pairs
    }
}
