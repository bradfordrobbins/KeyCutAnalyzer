import Foundation

/// One keyway's published geometry. Later keyways are additional values, not a new screen.
public struct KeySpec: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    /// Shoulder to cut center, in inches. Index 0 is the cut nearest the bow.
    public let stationsFromShoulderInches: [Double]
    /// How many leading stations this keyway uses. SC1 keeps a 6th station in the table and ignores it.
    public let stationsUsed: Int
    /// Root depth from the blade bottom, inches. Index is the bite number.
    public let rootDepthsInches: [Double]
    public let depthIncrementInches: Double
    /// Uncut blade height. Scale reference: straight bottom edge to the full height just off the shoulder.
    public let bladeHeightInches: Double
    /// Included cutter angle, degrees.
    public let cutAngleDegrees: Double
    /// Width of the flat at the root of each cut.
    public let rootFlatInches: Double
    /// Maximum adjacent cut specification. A difference greater than this is out of family.
    public let macs: Int
    /// Allowed root-depth error above the charted root, in inches.
    public let rootTolerancePlusInches: Double
    /// Allowed root-depth error below the charted root, in inches. Zero means the root must not measure under the chart.
    public let rootToleranceMinusInches: Double

    public init(
        id: String,
        displayName: String,
        stationsFromShoulderInches: [Double],
        stationsUsed: Int,
        rootDepthsInches: [Double],
        depthIncrementInches: Double,
        bladeHeightInches: Double,
        cutAngleDegrees: Double,
        rootFlatInches: Double,
        macs: Int,
        rootTolerancePlusInches: Double,
        rootToleranceMinusInches: Double
    ) {
        self.id = id
        self.displayName = displayName
        self.stationsFromShoulderInches = stationsFromShoulderInches
        self.stationsUsed = stationsUsed
        self.rootDepthsInches = rootDepthsInches
        self.depthIncrementInches = depthIncrementInches
        self.bladeHeightInches = bladeHeightInches
        self.cutAngleDegrees = cutAngleDegrees
        self.rootFlatInches = rootFlatInches
        self.macs = macs
        self.rootTolerancePlusInches = rootTolerancePlusInches
        self.rootToleranceMinusInches = rootToleranceMinusInches
    }

    public var usedStationsInches: [Double] {
        Array(stationsFromShoulderInches.prefix(stationsUsed))
    }
}

public enum KeyCatalog {
    /// Schlage SC1. Five cuts are read; the 1.012 in sixth station stays in the table.
    public static let sc1 = KeySpec(
        id: "SC1",
        displayName: "SC1",
        stationsFromShoulderInches: [0.231, 0.3872, 0.5434, 0.6996, 0.8558, 1.012],
        stationsUsed: 5,
        rootDepthsInches: [0.335, 0.320, 0.305, 0.290, 0.275, 0.260, 0.245, 0.230, 0.215, 0.200],
        depthIncrementInches: 0.015,
        bladeHeightInches: 0.343,
        cutAngleDegrees: 100,
        rootFlatInches: 0.031,
        macs: 7,
        rootTolerancePlusInches: 0.002,
        rootToleranceMinusInches: 0
    )

    public static let all: [KeySpec] = [sc1]

    public static func spec(id: String) -> KeySpec? {
        all.first { $0.id == id }
    }
}
