import AppKit
import Library
import Tokens

/// 一张卡此刻在屏幕上的样子：放大查看从它长出来、关掉时缩回它
public struct Spot {
    /// 在窗口里的位置和大小（左上为原点、y 向下，跟 SwiftUI 的全局坐标一致），不含旋转
    public let frame: CGRect
    public let rotation: Double
    /// 画布上显示的就是整张画面（图片、视频，没裁、没翻、不是长图）时，那张画面的文件；放大查看能拿它整张飞
    public let cover: String?
    /// 飞不了整张画面的卡（文字、网页……）此刻在画布上的样子：放大查看从它展开成面板
    public let face: CGImage?
    /// 是哪一份摆放：同一张卡放了几份时，关的时候回到打开的那份
    public let placement: Int64
}

extension CanvasView {
    /// 这一份摆放在眼前时的样子
    public func spot(_ placement: Int64) -> Spot? {
        guard let window, let height = window.contentView?.bounds.height,
              let layer = live[placement], let item = items[placement] else { return nil }
        let p = item.placement
        let c = screenPoint(CGPoint(x: p.frame.midX, y: p.frame.midY))
        let k = camera.scale * (layer.lifted ? CardShape.lift.scale : 1)
        let size = CGSize(width: p.width * k, height: p.height * k)
        let rect = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        guard rect.intersects(viewport) else { return nil }
        // 视图坐标 y 向下 → 窗口坐标（y 向上）→ SwiftUI 全局坐标（y 向下）
        let inWindow = convert(CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: size.width, height: size.height), to: nil)
        var cover: String?
        if case .card(let card) = item.face, card.kind == .image || card.kind == .video, card.form != .long,
           p.crop == nil, !p.flipX, !p.flipY {
            cover = card.cover
        }
        let face = cover == nil && item.placement.cardID != nil ? layer.content.contents.map { $0 as! CGImage } : nil
        return Spot(frame: CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height),
                    rotation: p.rotation, cover: cover, face: face, placement: placement)
    }

    /// 这张卡在眼前的那一份：选中的优先，否则按摆放编号取，每次取到的是同一份
    public func spot(ofCard card: Int64) -> Spot? {
        let copies = live.keys.filter { items[$0]?.cardID == card }
        return (copies.first(where: selection.contains) ?? copies.min()).flatMap { spot($0) }
    }

    /// 这张卡在不在眼前这块画布上（不论有没有滚到视野里）
    public func holds(card: Int64) -> Bool {
        items.values.contains { $0.cardID == card }
    }

    /// 卡被拿进放大查看：画布上这张连同选中框一起不见，像是被拿走了
    public func hide(_ spot: Spot) {
        live[spot.placement]?.isHidden = true
        overlay.isHidden = true
    }

    /// 放回来
    public func reveal(_ spot: Spot) {
        live[spot.placement]?.isHidden = false
        overlay.isHidden = false
    }
}
