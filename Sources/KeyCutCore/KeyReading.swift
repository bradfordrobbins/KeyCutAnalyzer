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
    /// Ends of the measured root flat, in image pixels.
    public let widthStart: Point2D
    public let widthEnd: Point2D
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
    /// Measured width of the root flat along the blade.
    public let cutWidthMillimeters: Double

    public var shoulderDistanceText: String {
        Units.formatInches(shoulderDistanceInches)
    }

    public var rootDepthText: String {
        Units.formatInches(rootDepthInches)
    }

    public var deviationText: String {
        Units.formatSignedInches(Units.inches(fromMillimeters: deviationMillimeters))
    }

    public var cutWidthText: String {
        Units.formatInches(Units.inches(fromMillimeters: cutWidthMillimeters))
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

    /// Rewrites image-space geometry through a crop-to-photo mapping. Cut depths stay the same.
    public func mapImagePoints(_ transform: (Point2D) -> Point2D) -> KeyReading {
        let origin = transform(pose.origin)
        let tipEnd = transform(pose.origin + pose.tipAxis)
        let bittingEnd = transform(pose.origin + pose.bittingAxis)
        let tipVector = tipEnd - origin
        let bittingVector = bittingEnd - origin
        let scale = tipVector.length()
        let movedPose = KeyPose(
            origin: origin,
            tipAxis: tipVector.normalized(),
            bittingAxis: bittingVector.normalized(),
            pixelsPerInch: pose.pixelsPerInch * (scale > 1e-9 ? scale : 1)
        )
        return KeyReading(
            specID: specID,
            code: code,
            cuts: cuts,
            macsViolations: macsViolations,
            macsWarning: macsWarning,
            pose: movedPose,
            overlay: OverlayGeometry(
                bottomStart: transform(overlay.bottomStart),
                bottomEnd: transform(overlay.bottomEnd),
                shoulderStart: transform(overlay.shoulderStart),
                shoulderEnd: transform(overlay.shoulderEnd),
                cuts: overlay.cuts.map { cut in
                    CutOverlay(
                        index: cut.index,
                        bottom: transform(cut.bottom),
                        root: transform(cut.root),
                        label: transform(cut.label),
                        widthStart: transform(cut.widthStart),
                        widthEnd: transform(cut.widthEnd)
                    )
                }
            )
        )
    }

    /// Moves image-space geometry from a crop back onto the full photo.
    public func translated(by offset: Point2D) -> KeyReading {
        guard offset.x != 0 || offset.y != 0 else { return self }
        func point(_ value: Point2D) -> Point2D {
            Point2D(value.x + offset.x, value.y + offset.y)
        }
        let movedPose = KeyPose(
            origin: point(pose.origin),
            tipAxis: pose.tipAxis,
            bittingAxis: pose.bittingAxis,
            pixelsPerInch: pose.pixelsPerInch
        )
        let movedOverlay = OverlayGeometry(
            bottomStart: point(overlay.bottomStart),
            bottomEnd: point(overlay.bottomEnd),
            shoulderStart: point(overlay.shoulderStart),
            shoulderEnd: point(overlay.shoulderEnd),
            cuts: overlay.cuts.map { cut in
                CutOverlay(
                    index: cut.index,
                    bottom: point(cut.bottom),
                    root: point(cut.root),
                    label: point(cut.label),
                    widthStart: point(cut.widthStart),
                    widthEnd: point(cut.widthEnd)
                )
            }
        )
        return KeyReading(
            specID: specID,
            code: code,
            cuts: cuts,
            macsViolations: macsViolations,
            macsWarning: macsWarning,
            pose: movedPose,
            overlay: movedOverlay
        )
    }

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
                CutOverlay(
                    index: cut.index,
                    bottom: point(cut.bottom),
                    root: point(cut.root),
                    label: point(cut.label),
                    widthStart: point(cut.widthStart),
                    widthEnd: point(cut.widthEnd)
                )
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
