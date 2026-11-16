import SwiftUI
import Tokens

/// 无边框的小按钮：悬停铺一层浅底，按下深一档，让人知道点得到。图标按钮用圆，文字按钮用胶囊
/// filled 的平时就铺着浅底（建议问题这种胶囊），悬停、按下各深一档
struct HoverButton<S: Shape>: ButtonStyle {
    let shape: S
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        Hovered(configuration: configuration, shape: shape, filled: filled)
    }

    private struct Hovered: View {
        let configuration: Configuration
        let shape: S
        let filled: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        /// 平时、悬停、按下，一档比一档深
        private var fill: AnyShapeStyle {
            let level = (filled ? 1 : 0) + (hovering && enabled ? 1 : 0) + (configuration.isPressed ? 1 : 0)
            return [AnyShapeStyle(.clear), AnyShapeStyle(.quaternary), AnyShapeStyle(.tertiary), AnyShapeStyle(.secondary)][level]
        }

        var body: some View {
            configuration.label
                .background(shape.fill(fill))
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(.spring(Motion.lift), value: hovering)
        }
    }
}

extension ButtonStyle where Self == HoverButton<Capsule> {
    /// 文字按钮
    static var hover: HoverButton<Capsule> { HoverButton(shape: Capsule()) }
}

extension ButtonStyle where Self == HoverButton<Capsule> {
    /// 平时就铺着浅底的胶囊：建议问题
    static var chip: HoverButton<Capsule> { HoverButton(shape: Capsule(), filled: true) }
}

extension ButtonStyle where Self == HoverButton<Circle> {
    /// 图标按钮
    static var hoverIcon: HoverButton<Circle> { HoverButton(shape: Circle()) }
}

extension ButtonStyle where Self == HoverButton<RoundedRectangle> {
    /// 列表里的一行
    static var hoverRow: HoverButton<RoundedRectangle> { HoverButton(shape: RoundedRectangle(cornerRadius: 8)) }
}
