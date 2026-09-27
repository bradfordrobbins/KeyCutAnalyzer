import Foundation

public struct KeyPose: Equatable, Sendable {
    /// Shoulder on the blade-bottom line, in image pixels.
    public let origin: Point2D
    /// Unit vector toward the tip, in image pixels.
    public let tipAxis: Point2D
    /// Unit vector from the blade bottom toward the bitting, in image pixels.
    public let bittingAxis: Point2D
    public let pixelsPerInch: Double

    public init(origin: Point2D, tipAxis: Point2D, bittingAxis: Point2D, pixelsPerInch: Double) {
        self.origin = origin
        self.tipAxis = tipAxis
        self.bittingAxis = bittingAxis
        self.pixelsPerInch = pixelsPerInch
    }

    public func imagePoint(keyX inchesX: Double, keyY inchesY: Double) -> Point2D {
        origin + tipAxis * (inchesX * pixelsPerInch) + bittingAxis * (inchesY * pixelsPerInch)
    }
}

public struct CutOverlay: Equatable, Sendable {
    public let index: Int
    public let bottom: Point2D
    public let root: Point2D
    public let label: Point2D
}

public struct OverlayGeometry: Equatable, Sendable {
    public let bottomStart: Point2D
    public let bottomEnd: Point2D
    public let shoulderStart: Point2D
    public let shoulderEnd: Point2D
    public let cuts: [CutOverlay]
}

public struct CutReading: Equatable, Sendable {
    public let index: Int
    public let bite: Int
    public let shoulderDistanceInches: Double
    public let shoulderDistanceMillimeters: Double
    public let rootDepthInches: Double
    public let rootDepthMillimeters: Double
    public let specRootDepthMillimeters: Double
    public let deviationMillimeters: Double
    public let outsideDepthTolerance: Bool

    public var shoulderDistanceText: String {
        Units.formatMillimeters(shoulderDistanceMillimeters)
    }

    public var rootDepthText: String {
        Units.formatMillimeters(rootDepthMillimeters)
    }

    public var deviationText: String {
        Units.formatSignedMillimeters(deviationMillimeters)
    }
}

public struct KeyReading: Equatable, Sendable {
    public let specID: String
    public let code: String
    public let cuts: [CutReading]
    public let macsViolations: [MACSViolation]
    public let macsWarning: String?
    public let pose: KeyPose
    public let overlay: OverlayGeometry

    /// Scales image-space geometry from a working raster back to the source frame.
    /// Cut depths and the bitting code are unchanged.
    public func scaled(by factor: Double) -> KeyReading {
        guard factor != 1 else { return self }
        func point(_ value: Point2D) -> Point2D {
            Point2D(value.x * factor, value.y * factor)
        }
        let scaledPose = KeyPose(
            origin: point(pose.origin),
            tipAxis: pose.tipAxis,
            bittingAxis: pose.bittingAxis,
            pixelsPerInch: pose.pixelsPerInch * factor
        )
        let scaledOverlay = OverlayGeometry(
            bottomStart: point(overlay.bottomStart),
            bottomEnd: point(overlay.bottomEnd),
            shoulderStart: point(overlay.shoulderStart),
            shoulderEnd: point(overlay.shoulderEnd),
            cuts: overlay.cuts.map { cut in
                CutOverlay(index: cut.index, bottom: point(cut.bottom), root: point(cut.root), label: point(cut.label))
            }
        )
        return KeyReading(
            specID: specID,
            code: code,
            cuts: cuts,
            macsViolations: macsViolations,
            macsWarning: macsWarning,
            pose: scaledPose,
            overlay: scaledOverlay
        )
    }
}
