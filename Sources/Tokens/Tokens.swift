// Design values: spacing, motion, colors and font sizes shared across the app. Numbers only; the canvas and the SwiftUI interface each convert them to their own form.
// New interfaces take values from here first instead of inventing new ones.

/// A color: 0–1 RGB plus opacity
public struct RGBA: Sendable, Equatable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
    public func opacity(_ a: Double) -> RGBA { RGBA(r, g, b, self.a * a) }
}

/// One for light, one for dark
public struct Themed<Value: Sendable>: Sendable {
    public var light: Value, dark: Value
    public init(light: Value, dark: Value) { (self.light, self.dark) = (light, dark) }
}

public enum Space {
    /// Grid unit (world coordinates), also the standard spacing between cards: used by the canvas, search results and inspiration layout
    public static let unit: Double = 20
    /// Row height (world coordinates) when tidying into rows and in several card views: four or five rows fit on screen at common zoom levels
    public static let rowHeight: Double = 220
}

/// The app has only four ways of moving. For a new animation, first decide which one it is instead of inventing new parameters
public enum Motion {
    public struct Spring: Sendable { public var response: Double, damping: Double }
    /// Cards changing position: gathering, scattering, dropping, tidying
    public static let place = Spring(response: 0.55, damping: 0.82)
    /// Small feedback at hand: hover, pick up, buttons
    public static let lift = Spring(response: 0.3, damping: 0.75)
    /// Fade in and out: overlays, panels, notices; also used when a card's content changes in front of you (understanding finished), since text changing too fast is jarring
    public static let fade: Double = 0.3
    /// Switching content: old and new views cross-fade when switching boards or the library. Shorter than fade, so quick repeated switches don't drag
    public static let swap: Double = 0.18
    /// Switching content start to finish: the new view fades in, the old one finishes fading half a beat later. Things changing along with it (the dimming behind the detail view) use this
    public static let swapSpan: Double = swap * 1.5
    /// An image flying from one place to another: the detail view flying out of a card and back. Ease in and out, crisp landing, so the panel right after doesn't wait for a spring's long tail
    public static let fly: Double = 0.4
    /// Size to start from when growing in: newly arrived cards, the detail view coming out of a card
    public static let emerge: Double = 0.92
    /// How long the mouse must rest on a card to count as stopped: passing over doesn't count; only then does a local video start previewing
    public static let dwell: Double = 0.3
    /// Waiting: the length of one cycle
    public static let wait: Double = 1.6
    /// How long a notice stays before fading out; ones with "Undo" stay twice as long so there's time to click
    public static let notice: Double = 3
    /// Flash: after clicking a citation in a discussion, how long the passage's highlight stays in the detail view before fading
    public static let flash: Double = 1.6
}

public enum Palette {
    /// Canvas background
    public static let canvas = Themed(light: RGBA(0.905, 0.9, 0.885), dark: RGBA(0.085, 0.085, 0.08))
    /// Background and text color of paper-like cards (text, web page, document): one clean set of colors, not swapping paper color by some random rule.
    /// Paper gets dark in dark mode too: the brightest things on screen should be images, not blocks of white paper
    public static let card = Themed(light: RGBA(0.985, 0.982, 0.972), dark: RGBA(0.165, 0.165, 0.16))
    public static let ink = Themed(light: RGBA(0.11, 0.11, 0.10), dark: RGBA(0.93, 0.93, 0.91))
    /// Secondary text (body excerpt) and fainter text (source, word count)
    public static let inkSecondary = Themed(light: ink.light.opacity(0.62), dark: ink.dark.opacity(0.62))
    public static let inkTertiary = Themed(light: ink.light.opacity(0.45), dark: ink.dark.opacity(0.45))
    /// Background before an image arrives
    public static let placeholder = Themed(light: RGBA(0.86, 0.85, 0.83), dark: RGBA(0.21, 0.21, 0.205))
    /// Selection, alignment guides, in progress
    public static let accent = RGBA(0.0, 0.48, 1.0)
    /// Broken
    public static let warning = RGBA(0.89, 0.45, 0.13)
    /// Dark and light overlays on images: badges, the video play mark
    public static let badge = RGBA(0, 0, 0, 0.5)
    public static let badgeInk = RGBA(1, 1, 1, 0.95)
    /// When a title sits on a cover, the cover's bottom darkens to this color so the text reads even on light covers
    public static let coverShade = RGBA(0, 0, 0, 0.6)
    /// Starting color of the fading layer under Back and the title at the top of the window: canvas background at 70%, fading to transparent downward, so the title stays readable when cards slide under the buttons
    public static let titleShade = Themed(light: canvas.light.opacity(0.7), dark: canvas.dark.opacity(0.7))
    /// Background before a video frame arrives
    public static let media = RGBA(0.08, 0.08, 0.08)
    /// Dimming layer over content: outside the crop frame
    public static let scrim = RGBA(0, 0, 0, 0.4)
    /// Dimming layer behind the detail view: only the card in front remains. A dark canvas is already dark, so it needs heavier dimming to separate the layers
    public static let backdrop = Themed(light: RGBA(0, 0, 0, 0.45), dark: RGBA(0, 0, 0, 0.7))
    /// Background of the image area and the text area in the detail view: both opaque, so the canvas behind doesn't show through
    public static let stage = Themed(light: RGBA(0.93, 0.928, 0.92), dark: RGBA(0.075, 0.075, 0.07))
    public static let page = Themed(light: RGBA(0.992, 0.99, 0.985), dark: RGBA(0.135, 0.135, 0.13))
    /// Swatches for the twelve nameable colors on the search color filter buttons (by color name)
    public static let swatches: [String: RGBA] = [
        "red": RGBA(0.82, 0.20, 0.18), "orange": RGBA(0.93, 0.52, 0.16), "yellow": RGBA(0.95, 0.80, 0.22),
        "green": RGBA(0.30, 0.58, 0.32), "cyan": RGBA(0.20, 0.66, 0.70), "blue": RGBA(0.20, 0.38, 0.78),
        "purple": RGBA(0.52, 0.32, 0.70), "pink": RGBA(0.93, 0.58, 0.70), "brown": RGBA(0.50, 0.34, 0.22),
        "black": RGBA(0.10, 0.10, 0.10), "white": RGBA(0.97, 0.97, 0.95), "gray": RGBA(0.55, 0.55, 0.55),
    ]
    /// Backgrounds your text cards can switch to, in menu order; none chosen means the card's own background. Light mode: light background, dark text; dark mode: same hue one step darker, with light text
    public static let tints: [(name: String, color: Themed<RGBA>)] = [
        ("yellow", Themed(light: RGBA(0.99, 0.94, 0.70), dark: RGBA(0.33, 0.29, 0.13))),
        ("pink", Themed(light: RGBA(0.98, 0.87, 0.88), dark: RGBA(0.35, 0.21, 0.23))),
        ("blue", Themed(light: RGBA(0.85, 0.91, 0.98), dark: RGBA(0.17, 0.25, 0.37))),
        ("green", Themed(light: RGBA(0.87, 0.94, 0.84), dark: RGBA(0.19, 0.30, 0.20))),
        ("purple", Themed(light: RGBA(0.91, 0.88, 0.97), dark: RGBA(0.27, 0.23, 0.39))),
    ]
    /// Text card background: nil or an unknown name means the card's own background
    public static func tint(_ name: String?) -> Themed<RGBA> { tints.first { $0.name == name }?.color ?? card }
    /// Library group headers, drawn directly on the canvas background: group name, then a fainter count and "select this group"
    public static let shelfTitle = Themed(light: RGBA(0.11, 0.11, 0.10, 0.78), dark: RGBA(1, 1, 1, 0.82))
    public static let shelfNote = Themed(light: RGBA(0.11, 0.11, 0.10, 0.42), dark: RGBA(1, 1, 1, 0.42))
    /// When search results gather or literal hits light up, other cards recede into the background: covered with a layer of canvas background this opaque
    public static let recede = 0.86
    /// While typing, cards with literal hits light up in place: other cards only fade this much. It's a hint, not a mode change, so much lighter than gathering
    public static let hint = 0.5
    /// Flash background: the system's find highlight color, this opaque
    public static let flash = 0.45
}

/// Sizes of interface floating over the canvas (search bar, filter buttons, text panel), in screen points
public enum Chrome {
    /// Distance from overlays to the window edge, also the large spacing between overlays
    public static let inset: Double = 20
    /// Small spacing: between the search bar and filter buttons, between buttons
    public static let gap: Double = 10
    public static let searchHeight: Double = 44
    public static let searchWidth: Double = 560
    public static let chipHeight: Double = 26
    public static let panelWidth: Double = 300
    /// Where gathered cards must keep clear: the search bar and filter buttons at the bottom, the text panel on the right
    public static let searchReserve = inset + searchHeight + gap + chipHeight + inset
    public static let panelReserve = panelWidth + inset * 2
}

/// Font sizes and spacing for the reading page (text in the detail view), in screen points. Wide is the full reading page, narrow is the column beside the image
public enum Reading {
    public struct Scale: Sendable, Equatable {
        /// Title, description and key points, body
        public var title, lead, body: Double
        public var lineSpacing, paragraphSpacing: Double
        /// Margins all around, and spacing between blocks (half that within a block)
        public var padding, gap: Double
    }
    public static let wide = Scale(title: 28, lead: 16, body: 16, lineSpacing: 10, paragraphSpacing: 14, padding: 40, gap: 24)
    public static let narrow = Scale(title: 20, lead: 14, body: 14, lineSpacing: 6, paragraphSpacing: 10, padding: 24, gap: 18)
    /// Width of the full reading page and of its text column; width of the column beside the image
    public static let pageWidth: Double = 820
    public static let column: Double = 640
    public static let narrowWidth: Double = 340
}

public enum CardShape {
    /// Card corner radius (world coordinates). Images have their own edges and aren't rounded; only paper-like cards (text, web page, document, audio)
    public static let corner: Double = 6
    /// Card shadow: opacity, radius, downward offset (world coordinates)
    public static let shadow = (opacity: 0.15, radius: 3.0, offset: 1.0)
    /// Picked up on hover: how much to enlarge, how much to deepen the shadow
    public static let lift = (scale: 1.025, opacity: 0.28, radius: 10.0, offset: 4.0)
}

/// Text layout on cards. All proportions of the card width, so the layout holds as cards scale
public enum CardType {
    public static let padding = 0.08
    /// Short text (quote card): font size and line spacing for Chinese and Western text
    public static let quoteCJK = 0.088
    public static let quoteLatin = 0.082
    public static let lineSpacing = 0.022
    /// About 9 characters per line for Chinese, about 19 letters for English, used to estimate how tall a quote card is
    public static let quoteCharsPerLine = (cjk: 9.0, latin: 19.0)
    /// Title, body, bottom line (source, word count, domain)
    public static let title = 0.078
    public static let body = 0.046
    public static let footer = 0.036
    /// Gap between title and body, body line spacing
    public static let gap = 0.03
    public static let bodyLineSpacing = 0.012
    /// Badge text
    public static let badge = 0.038
    /// Diameter of the play mark: the one in the middle of a video cover, the play button on audio cards
    public static let playMark = 0.16
    /// Gap between key points
    public static let pointSpacing = 0.016
    /// When body text follows, the most of this area key points may take: the rest shows a few lines of body
    public static let pointsShare = 0.6
    /// How short counts as short text: short text becomes a quote card, long text shows title, key points and the first few paragraphs
    public static let shortTextLimit = 140
    /// Font size for the body of text cards you write: larger than article body, readable even zoomed out on the canvas
    public static let note = 0.062
}
