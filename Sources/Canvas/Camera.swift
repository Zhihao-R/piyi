import CoreGraphics
import Tokens

/// Viewport: a center point in world coordinates + a zoom factor. Screen point = (world point - center) × scale + view size / 2 (y down)
public struct Camera: Equatable, Sendable {
    public var center: CGPoint
    public var scale: CGFloat

    public static let scales: ClosedRange<CGFloat> = 0.02...4

    public init(center: CGPoint, scale: CGFloat) {
        self.center = center
        self.scale = scale
    }

    public func visibleRect(in size: CGSize) -> CGRect {
        let w = size.width / scale, h = size.height / scale
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    /// World coordinates of a point in the view (y down)
    public func world(at point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: center.x + (point.x - size.width / 2) / scale, y: center.y + (point.y - size.height / 2) / scale)
    }

    /// Where a world point sits in the view (y down)
    public func view(at point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - center.x) * scale + size.width / 2, y: (point.y - center.y) * scale + size.height / 2)
    }

    /// Fit exactly one region in view, with a little margin around it
    public static func fitting(_ rect: CGRect, in size: CGSize, margin: CGFloat = 40) -> Camera {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return Camera(center: .zero, scale: 1) }
        let scale = min((size.width - margin * 2) / rect.width, (size.height - margin * 2) / rect.height, 1)
        return Camera(center: CGPoint(x: rect.midX, y: rect.midY), scale: min(max(scale, scales.lowerBound), scales.upperBound))
    }
}

/// Parameters of the window's screen, read once when the window goes on screen. Bitmaps are drawn in the screen's color space, so nothing has to be converted on the main thread when handing them to layers
enum Screen {
    /// The window currently has a dark appearance: paper-style cards take their colors from it (also read when drawing bitmaps in the background)
    nonisolated(unsafe) static var dark = false
    nonisolated(unsafe) static var scale: CGFloat = 2
    nonisolated(unsafe) static var colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
}

extension Themed {
    /// The value for the window's current appearance
    var now: Value { Screen.dark ? dark : light }
}
