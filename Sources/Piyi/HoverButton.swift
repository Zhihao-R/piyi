import SwiftUI
import Tokens

/// A small borderless button: hovering lays a light background, pressing goes one shade darker, so people know it's clickable. Icon buttons are circles, text buttons capsules
/// filled ones have the light background all the time (capsules like suggested questions); hover and press each go one shade darker
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

        /// Normal, hover, pressed, each darker than the last
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
    /// Text button
    static var hover: HoverButton<Capsule> { HoverButton(shape: Capsule()) }
}

extension ButtonStyle where Self == HoverButton<Capsule> {
    /// Capsule with a light background all the time: suggested questions
    static var chip: HoverButton<Capsule> { HoverButton(shape: Capsule(), filled: true) }
}

extension ButtonStyle where Self == HoverButton<Circle> {
    /// Icon button
    static var hoverIcon: HoverButton<Circle> { HoverButton(shape: Circle()) }
}

extension ButtonStyle where Self == HoverButton<RoundedRectangle> {
    /// A row in a list
    static var hoverRow: HoverButton<RoundedRectangle> { HoverButton(shape: RoundedRectangle(cornerRadius: 8)) }
}
