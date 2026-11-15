import CoreGraphics
import Tokens

/// 视口：世界坐标里的中心点 + 缩放倍数。屏幕点 = (世界点 - center) × scale + 视图尺寸 / 2（y 向下）
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

    /// 视图里的点（y 向下）对应的世界坐标
    public func world(at point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: center.x + (point.x - size.width / 2) / scale, y: center.y + (point.y - size.height / 2) / scale)
    }

    /// 世界坐标的点在视图里的位置（y 向下）
    public func view(at point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - center.x) * scale + size.width / 2, y: (point.y - center.y) * scale + size.height / 2)
    }

    /// 刚好看全一块区域，四周留一点边
    public static func fitting(_ rect: CGRect, in size: CGSize, margin: CGFloat = 40) -> Camera {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return Camera(center: .zero, scale: 1) }
        let scale = min((size.width - margin * 2) / rect.width, (size.height - margin * 2) / rect.height, 1)
        return Camera(center: CGPoint(x: rect.midX, y: rect.midY), scale: min(max(scale, scales.lowerBound), scales.upperBound))
    }
}

/// 窗口所在屏幕的参数，窗口上屏时读一次。位图按屏幕的颜色空间画，提交给图层时不必再在主线程整张转换
enum Screen {
    /// 窗口现在是深色外观：纸样卡片按它取颜色（后台画位图时也读它）
    nonisolated(unsafe) static var dark = false
    nonisolated(unsafe) static var scale: CGFloat = 2
    nonisolated(unsafe) static var colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
}

extension Themed {
    /// 窗口当前外观下的那一个值
    var now: Value { Screen.dark ? dark : light }
}
