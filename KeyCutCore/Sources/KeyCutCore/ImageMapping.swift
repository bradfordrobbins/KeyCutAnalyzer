import Foundation

public enum PreviewGravity: Sendable, Equatable {
    case resizeAspectFit
    case resizeAspectFill
}

public enum ImageMapping {
    /// Maps a point in an upright image (origin top-left, y down) into a view that letterboxes or crops it.
    /// `quarterTurnsClockwise` rotates the image before the gravity fit, matching a preview that is turned upright.
    public static func viewPoint(
        imagePoint: Point2D,
        imageSize: Size2D,
        viewSize: Size2D,
        quarterTurnsClockwise: Int,
        gravity: PreviewGravity
    ) -> Point2D {
        let turns = ((quarterTurnsClockwise % 4) + 4) % 4
        let rotated = rotate(imagePoint, imageSize: imageSize, quarterTurnsClockwise: turns)
        let rotatedSize = turns % 2 == 0
            ? imageSize
            : Size2D(width: imageSize.height, height: imageSize.width)
        guard rotatedSize.width > 0, rotatedSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }
        let scaleX = viewSize.width / rotatedSize.width
        let scaleY = viewSize.height / rotatedSize.height
        let scale: Double
        switch gravity {
        case .resizeAspectFit:
            scale = min(scaleX, scaleY)
        case .resizeAspectFill:
            scale = max(scaleX, scaleY)
        }
        let displayedWidth = rotatedSize.width * scale
        let displayedHeight = rotatedSize.height * scale
        let originX = (viewSize.width - displayedWidth) / 2
        let originY = (viewSize.height - displayedHeight) / 2
        return Point2D(x: originX + rotated.x * scale, y: originY + rotated.y * scale)
    }

    private static func rotate(_ point: Point2D, imageSize: Size2D, quarterTurnsClockwise: Int) -> Point2D {
        switch quarterTurnsClockwise {
        case 0:
            return point
        case 1:
            return Point2D(x: imageSize.height - point.y, y: point.x)
        case 2:
            return Point2D(x: imageSize.width - point.x, y: imageSize.height - point.y)
        default:
            return Point2D(x: point.y, y: imageSize.width - point.x)
        }
    }
}
