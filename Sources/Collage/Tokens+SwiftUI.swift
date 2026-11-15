import SwiftUI
import Tokens

/// 设计数值转成 SwiftUI 的写法
extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

extension Animation {
    /// 淡入淡出：浮层、面板、提示
    static let fade = Animation.easeOut(duration: Motion.fade)
    /// 换内容：放大查看按方向键换卡、飞过来的图换成真图
    static let swap = Animation.easeOut(duration: Motion.swap)
    /// 当作旧画面的一部分淡出：跟画布的旧画面一样晚半拍开始、匀速淡完（见 Swap.swift 的 liftCurtain）
    static let swapOut = Animation.linear(duration: Motion.swap).delay(Motion.swap / 2)
    /// 跟着画布换内容一起变：同起同止
    static let swapSpan = Animation.easeInOut(duration: Motion.swapSpan)

    /// 一张图飞过去：落地干脆
    static let fly = Animation.timingCurve(0.45, 0, 0.15, 1, duration: Motion.fly)

    /// 设计数值里的弹簧
    static func spring(_ s: Motion.Spring) -> Animation { .spring(response: s.response, dampingFraction: s.damping) }
}

extension Themed where Value == RGBA {
    /// 跟着窗口深浅色变的颜色
    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
    }
}
