import SwiftUI
import Tokens

/// Design values converted to SwiftUI form
extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

extension Animation {
    /// Fade in and out: overlays, panels, hints
    static let fade = Animation.easeOut(duration: Motion.fade)
    /// Content change: switching cards with arrow keys in detail view, the flown-in image swapped for the real one
    static let swap = Animation.easeOut(duration: Motion.swap)
    /// Fade out as part of the old view: like the canvas's old view, start half a beat late and fade at a constant rate (see liftCurtain in Swap.swift)
    static let swapOut = Animation.linear(duration: Motion.swap).delay(Motion.swap / 2)
    /// Changes along with the canvas content: starting and ending together
    static let swapSpan = Animation.easeInOut(duration: Motion.swapSpan)

    /// An image flies over: lands crisply
    static let fly = Animation.timingCurve(0.45, 0, 0.15, 1, duration: Motion.fly)

    /// The spring from the design values
    static func spring(_ s: Motion.Spring) -> Animation { .spring(response: s.response, dampingFraction: s.damping) }
}

extension Themed where Value == RGBA {
    /// Colors that follow the window's light/dark appearance
    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
    }
}
