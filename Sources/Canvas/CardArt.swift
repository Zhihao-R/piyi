import AppKit
import CoreText
import Library
import Tokens

/// Card appearance: draws a card into a bitmap in the background. One record, one clean card; every visual difference conveys one piece of information (type, format, state).
/// Layout values are all relative to the card width (Tokens.CardType), so the layout stays the same as the card grows or shrinks.
struct CardArt {
    let face: Face
    let size: CGSize
    /// The cover, already cut to the crop frame and decoded at a suitable size; nil when there is no cover
    let cover: CGImage?
    /// The temporary enlargement factor while gathering
    var zoom: CGFloat = 1
    /// Placed by sorting and not yet viewed by you: marked "New" at the top right
    var unseen = false
    /// Draws only the badges sitting on the picture, transparent elsewhere: laid over the playing picture during video hover preview, so duration, platform, and status stay visible
    var marksOnly = false

    /// Draws a bitmap of size × pixelScale pixels
    func render(pixelScale: CGFloat) -> CGImage? {
        let w = Int((size.width * pixelScale).rounded(.up)), h = Int((size.height * pixelScale).rounded(.up))
        guard let ctx = screenBitmap(width: w, height: h) else { return nil }
        // Round width and height separately, then fill the actual pixels: scaling only by pixelScale leaves the sub-pixel remainder of rounding as an empty row, which shows as a white line along the card's top edge
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        var pen = Pen(ctx: ctx, size: size, pixelScale: pixelScale)
        switch face {
        case .card(let card): draw(card, &pen)
        case .entry(_, let name, _): entry(name, &pen)
        }
        return ctx.makeImage()
    }

    private var w: CGFloat { size.width }
    /// Font size and margins are computed from this width. Text cards always use the default width: stretching only enlarges the layout area, not the font size; other cards use their actual width and scale as a whole
    private var t: CGFloat { Self.reflows(face) ? CardSize.typeWidth * zoom : w }

    /// Text cards (text, articles, web pages and documents without a cover): re-laid out when stretched, not scaled up as a whole
    static func reflows(_ face: Face) -> Bool {
        guard case .card(let card) = face else { return false }
        return card.kind == .text || isArticle(card) || (card.kind == .web || card.kind == .document) && card.cover == nil
    }

    /// Web page with a cover and body text: title over the cover, key points and body below. Only the extracted body counts, not the one-line description the model writes
    static func isArticle(_ card: CardFace) -> Bool { card.kind == .web && card.cover != nil && card.length > 0 }

    private func draw(_ card: CardFace, _ pen: inout Pen) {
        switch card.kind {
        case .image:
            pen.fill(Palette.placeholder.now)
            if let cover { pen.image(cover, in: pen.bounds) }
            var badges: [String] = []
            if card.form == .long { badges.append(String(localized: "长图")) }
            if card.form == .animated { badges.append(card.format.map(displayed) ?? "GIF") }
            if card.images > 1 { badges.append(String(localized: "\(card.images) 张")) }
            if let platform = card.format, card.url != nil, card.form == nil { badges.append(displayed(platform)) }
            pen.badges(badges, w: t)
        case .text where card.form == .note:
            note(card, &pen)
        case .text:
            if card.isOwnText, card.length <= CardType.shortTextLimit { quote(card, &pen) } else { article(card, footer: String(localized: "\(card.length) 字"), &pen) }
        case .web:
            // With a platform badge (WeChat Official Accounts, Xiaohongshu), the bottom shows the author; otherwise the site
            let footer = card.format != nil ? card.source : card.site ?? card.source
            if let cover, Self.isArticle(card) {
                reading(cover, card, footer: footer, &pen)
            } else if let cover {
                withCover(cover, card, footer: footer, &pen)
            } else {
                article(card, footer: footer, &pen)
            }
            if let platform = card.format { pen.badges([displayed(platform)], w: t) }
        case .document:
            let label = [card.format.map(displayed), card.pages.map { String(localized: "\($0) 页") }].compactMap { $0 }.joined(separator: " · ")
            if let cover {
                pen.fill(Palette.card.now)
                pen.image(cover, in: pen.bounds)
                pen.badges(label.isEmpty ? [] : [label], w: t, bottom: true)
            } else {
                article(card, footer: label.isEmpty ? card.source : label, &pen)
            }
        case .video:
            if !marksOnly {
                pen.fill(Palette.media)
                if let cover { pen.image(cover, in: pen.bounds) }
                pen.playMark(w: t)
            }
            pen.badges([card.format.map(displayed)].compactMap { $0 }, w: t)
            if let d = card.duration { pen.badges([Self.clock(d)], w: t, bottom: true, trailing: true) }
        case .audio:
            pen.fill(Palette.card.now)
            let wave = Self.waveform
            pen.waveform(in: CGRect(x: w * wave.minX, y: size.height * wave.minY, width: w * wave.width, height: size.height * wave.height))
            let p = t * CardType.padding
            pen.text(card.title.isEmpty ? (card.source ?? "") : card.title, size: t * CardType.title, weight: .semibold,
                     color: Palette.ink.now, in: CGRect(x: p, y: size.height * 0.56, width: w - p * 2, height: size.height * 0.28))
            pen.text([card.duration.map(Self.clock), card.format.map(displayed)].compactMap { $0 }.joined(separator: " · "), size: t * CardType.footer,
                     color: Palette.inkTertiary.now, in: footerRect)
        }
        state(card, &pen)
        if unseen { pen.badges([String(localized: "新")], w: t, trailing: true) }
    }

    /// The area the waveform takes on an audio card (relative to card width and height). The play button sits right in its center (see CanvasView.playButtons)
    static let waveform = CGRect(x: 0.3, y: 0.18, width: 0.4, height: 0.32)

    /// Short text: a quote card, Song / serif typeface, with plenty of white space
    private func quote(_ card: CardFace, _ pen: inout Pen) {
        pen.fill(Palette.card.now)
        let p = t * CardType.padding
        let cjk = Self.isCJK(card.excerpt)
        let font = cjk ? NSFont(name: "Songti SC", size: pen.fontSize(t * CardType.quoteCJK)).map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
            : Pen.serif(pen.fontSize(t * CardType.quoteLatin))
        pen.text(card.excerpt, font: font ?? Pen.serif(pen.fontSize(t * CardType.quoteCJK)), color: Palette.ink.now, lineSpacing: t * CardType.lineSpacing,
                 in: CGRect(x: p, y: p, width: w - p * 2, height: size.height - p * 2 - t * CardType.footer * 1.6))
        pen.text(card.source ?? "", size: t * CardType.footer, color: Palette.inkTertiary.now, in: footerRect)
    }

    /// A text card you wrote: background color of your choice, Markdown laid out; what doesn't fit fades out at the bottom
    private func note(_ card: CardFace, _ pen: inout Pen) {
        let paper = Palette.tint(card.tint).now
        pen.fill(paper)
        let p = t * CardType.padding, bottom = size.height - p
        pen.text(Markdown.rendered(card.excerpt, style: Self.noteStyle(t: t, round: pen.fontSize) { $0.cg }), in: CGRect(x: p, y: p, width: w - p * 2, height: bottom - p))
        pen.fade(paper, from: bottom - t * 0.12, to: bottom)
    }

    /// Text card layout: the same for drawing the card and for editing, only the colors are specified differently
    static func noteStyle(t: CGFloat, round: @escaping (CGFloat) -> CGFloat = { $0 }, ink: @escaping (RGBA) -> Any) -> Markdown.Style {
        var style = Markdown.Style(body: t * CardType.note, lineSpacing: t * CardType.bodyLineSpacing) { ink($0.cardColor) }
        style.round = round
        return style
    }

    /// Long text, web pages and documents without images: title + key points + first few paragraphs, fading out at the bottom + one line of source
    private func article(_ card: CardFace, footer: String?, _ pen: inout Pen) {
        pen.fill(Palette.card.now)
        let p = t * CardType.padding
        var y = p
        if !card.title.isEmpty {
            y += pen.text(card.title, size: t * CardType.title, weight: .bold, color: Palette.ink.now, maxLines: 3,
                          in: CGRect(x: p, y: y, width: w - p * 2, height: size.height - y - p)) + t * CardType.gap
        }
        let bodyBottom = size.height - p - t * CardType.footer * 1.8
        let body = card.excerpt == card.title ? "" : card.excerpt
        y += points(card, at: y, bottom: bodyBottom, sharing: !body.isEmpty, &pen)
        let column = CGRect(x: p, y: y, width: w - p * 2, height: max(0, bodyBottom - y))
        if Markdown.applies(to: card) {
            var style = Markdown.Style(body: t * CardType.body, lineSpacing: t * CardType.bodyLineSpacing) { ink in
                (ink == .primary ? Palette.inkSecondary.now : ink.cardColor).cg
            }
            style.round = pen.fontSize
            pen.text(Markdown.rendered(Markdown.droppingTitle(card.title, from: body), style: style), in: column)
        } else {
            pen.text(body, size: t * CardType.body, color: Palette.inkSecondary.now, lineSpacing: t * CardType.bodyLineSpacing, in: column)
        }
        pen.fade(Palette.card.now, from: bodyBottom - t * 0.18, to: bodyBottom)
        pen.text(footer ?? "", size: t * CardType.footer, color: Palette.inkTertiary.now, in: footerRect)
    }

    /// Article with a cover: title over the bottom of the cover, below it key points first, then body. When stretched the cover only gets wider; all extra height goes to showing more text
    private func reading(_ cover: CGImage, _ card: CardFace, footer: String?, _ pen: inout Pen) {
        pen.fill(Palette.card.now)
        let p = t * CardType.padding
        let titleSize = t * CardType.title
        let titleHeight = pen.height(card.title, font: .systemFont(ofSize: pen.fontSize(titleSize), weight: .bold), maxLines: 3, width: w - p * 2)
        // The cover must at least fit the title, with room above for the badges
        let coverHeight = max(min(w * CardSize.coverShare(CGFloat(cover.height) / CGFloat(cover.width)), size.height * 0.6),
                              titleHeight + p * 2 + t * CardType.badge * 2.4)
        pen.image(cover, in: CGRect(x: 0, y: 0, width: w, height: coverHeight))
        let titleTop = coverHeight - p - titleHeight
        pen.fade(Palette.coverShade, from: max(0, titleTop - p * 2), to: coverHeight)
        pen.text(card.title, size: titleSize, weight: .bold, color: Palette.badgeInk,
                 in: CGRect(x: p, y: titleTop, width: w - p * 2, height: titleHeight + 1))

        let bottom = size.height - p - t * CardType.footer * 1.8
        var y = coverHeight + p * 0.9
        y += points(card, at: y, bottom: bottom, sharing: card.excerpt != card.title, &pen)
        if card.excerpt != card.title {
            pen.text(card.excerpt, size: t * CardType.body, color: Palette.inkSecondary.now, lineSpacing: t * CardType.bodyLineSpacing,
                     in: CGRect(x: p, y: y, width: w - p * 2, height: max(0, bottom - y)))
        }
        pen.fade(Palette.card.now, from: bottom - t * 0.18, to: bottom)
        pen.text(footer ?? "", size: t * CardType.footer, color: Palette.inkTertiary.now, in: footerRect)
    }

    /// Key points go before the body: on the canvas you just glance, and key points say what the piece is about better than its first few sentences. One paragraph per point; wrapped lines align with the text after the bullet.
    /// When body text follows (sharing), key points don't take all the space: the card's size was set when collected, before there were key points, so points that don't fit are dropped whole, leaving room for a few lines of body.
    /// Returns the height used (including the gap before the body); 0 when there are no key points
    private func points(_ card: CardFace, at y: CGFloat, bottom: CGFloat, sharing: Bool, _ pen: inout Pen) -> CGFloat {
        guard let summary = card.summary else { return 0 }
        let p = t * CardType.padding, width = w - p * 2, room = max(0, bottom - y)
        let font = NSFont.systemFont(ofSize: pen.fontSize(t * CardType.body))
        let lineSpacing = t * CardType.bodyLineSpacing, spacing = t * CardType.pointSpacing
        var shown: [Substring] = [], used: CGFloat = 0
        for point in summary.split(separator: "\n") {
            let height = pen.height(String(point), font: font, lineSpacing: lineSpacing, hanging: "· ", maxLines: .max, width: width) + spacing
            // The first one is always drawn
            if sharing, !shown.isEmpty, used + height > room * CardType.pointsShare { break }
            shown.append(point)
            used += height
        }
        return pen.text(shown.joined(separator: "\n"), font: font, color: Palette.ink.now, lineSpacing: lineSpacing, paragraphSpacing: spacing, hanging: "· ",
                        in: CGRect(x: p, y: y, width: width, height: room)) + t * CardType.gap
    }

    /// Web page with a cover but no body: cover + a bar below with title and site
    private func withCover(_ cover: CGImage, _ card: CardFace, footer: String?, _ pen: inout Pen) {
        pen.fill(Palette.card.now)
        let p = t * CardType.padding
        let bar = min(size.height * 0.45, w * 0.34)
        pen.image(cover, in: CGRect(x: 0, y: 0, width: w, height: size.height - bar))
        pen.text(card.title, size: t * CardType.title, weight: .bold, color: Palette.ink.now, maxLines: 2,
                 in: CGRect(x: p, y: size.height - bar + p * 0.8, width: w - p * 2, height: bar - p * 0.8 - t * CardType.footer * 1.8))
        pen.text(footer ?? "", size: t * CardType.footer, color: Palette.inkTertiary.now, in: footerRect)
    }

    /// Board entry: the board name, with a line "Board" below
    private func entry(_ name: String, _ pen: inout Pen) {
        pen.fill(Palette.placeholder.now)
        if let cover { pen.image(cover, in: pen.bounds) }
        let bar = w * 0.22
        pen.rect(CGRect(x: 0, y: size.height - bar, width: w, height: bar), Palette.card.now)
        let p = t * CardType.padding
        pen.text(name, size: t * CardType.title, weight: .bold, color: Palette.ink.now, maxLines: 1,
                 in: CGRect(x: p, y: size.height - bar + bar * 0.18, width: w - p * 2, height: bar * 0.5))
        pen.text(String(localized: "画板"), size: t * CardType.footer, color: Palette.inkTertiary.now, in: CGRect(x: p, y: size.height - bar * 0.38, width: w - p * 2, height: bar * 0.3))
    }

    /// Extracting, incomplete, understanding in progress: a lightweight indicator
    private func state(_ card: CardFace, _ pen: inout Pen) {
        if card.extraction == .extracting {
            pen.rect(pen.bounds, Palette.card.now.opacity(0.6))
            pen.badges([String(localized: "正在抽取")], w: t, color: Palette.accent)
        } else if card.partial != nil {
            pen.badges([String(localized: "残缺")], w: t, bottom: true, color: Palette.warning)
        } else if card.understanding == .generating {
            pen.badges([String(localized: "正在理解")], w: t, bottom: true)
        }
    }

    private var footerRect: CGRect {
        let p = t * CardType.padding
        return CGRect(x: p, y: size.height - p - t * CardType.footer * 1.3, width: w - p * 2, height: t * CardType.footer * 1.4)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func isCJK(_ text: String) -> Bool { text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
}

/// The pen for drawing cards: coordinates are points with origin at top left and y down (the card's world coordinate units), converted internally to Core Graphics' bottom-left origin
struct Pen {
    let ctx: CGContext
    let size: CGSize
    let pixelScale: CGFloat
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    /// Font sizes are rounded to whole pixels: the layout varies continuously with card width, and without rounding nearly every card would get its own font size;
    /// the system caches glyphs separately per font size, which costs tens of MB more with 5000 cards
    func fontSize(_ points: CGFloat) -> CGFloat { max(1, (points * pixelScale).rounded()) / pixelScale }

    /// Top-left-origin rect → Core Graphics rect
    private func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }

    func fill(_ color: RGBA) { rect(bounds, color) }

    func rect(_ r: CGRect, _ color: RGBA) {
        ctx.setFillColor(color.cg)
        ctx.fill(flip(r))
    }

    /// Image fills the rect, with the excess cropped (aligned to the top edge: long images show only the top)
    func image(_ image: CGImage, in r: CGRect) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let k = max(r.width / iw, r.height / ih)
        let drawn = CGRect(x: r.midX - iw * k / 2, y: r.minY, width: iw * k, height: ih * k)
        ctx.saveGState()
        ctx.clip(to: flip(r))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: flip(drawn))
        ctx.restoreGState()
    }

    /// Fade from from to to into the background color (covering truncated body text)
    func fade(_ color: RGBA, from: CGFloat, to: CGFloat) {
        guard to > from, let gradient = CGGradient(colorsSpace: Screen.colorSpace, colors: [color.opacity(0).cg, color.cg] as CFArray, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: flip(CGRect(x: 0, y: from, width: size.width, height: to - from)))
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height - from), end: CGPoint(x: 0, y: size.height - to), options: [])
        ctx.restoreGState()
    }

    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// Writes a paragraph laid out from the top of the rect, cutting off what doesn't fit. Returns the height actually used.
    /// hanging: the bullet at the start of each paragraph; wrapped lines align with the text after the bullet
    @discardableResult
    func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: RGBA, lineSpacing: CGFloat = 0,
              paragraphSpacing: CGFloat = 0, hanging: String? = nil, maxLines: Int = 0, in r: CGRect) -> CGFloat {
        text(string, font: .systemFont(ofSize: fontSize(size), weight: weight), color: color, lineSpacing: lineSpacing,
             paragraphSpacing: paragraphSpacing, hanging: hanging, maxLines: maxLines, in: r)
    }

    /// Measure without drawing: how tall it is laid out at this width, at most maxLines lines
    func height(_ string: String, font: NSFont, lineSpacing: CGFloat = 0, hanging: String? = nil, maxLines: Int, width: CGFloat) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let text = Self.attributed(string, font: font, color: Palette.ink.now, lineSpacing: lineSpacing, hanging: hanging)
        return Self.height(CTFramesetterCreateWithAttributedString(text), maxLines: maxLines, width: width)
    }

    /// Measures the height from the first maxLines lines actually laid out: Chinese fonts have taller lines than the system font's nominal value, so estimating by the nominal value would lay out one line too few
    private static func height(_ setter: CTFramesetter, maxLines: Int, width: CGFloat) -> CGFloat {
        let tall: CGFloat = 10_000
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: tall), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        let n = min(lines.count, maxLines)
        guard n > 0 else { return 0 }
        var origin = CGPoint.zero, descent: CGFloat = 0
        CTFrameGetLineOrigins(frame, CFRange(location: n - 1, length: 1), &origin)
        CTLineGetTypographicBounds(lines[n - 1], nil, &descent, nil)
        return ceil(tall - origin.y + descent)
    }

    private static func attributed(_ string: String, font: NSFont, color: RGBA, lineSpacing: CGFloat = 0,
                                   paragraphSpacing: CGFloat = 0, hanging: String? = nil) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.lineBreakMode = .byWordWrapping
        if let hanging { style.headIndent = NSAttributedString(string: hanging, attributes: [.font: font]).size().width }
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color.cg, .paragraphStyle: style])
    }

    @discardableResult
    func text(_ string: String, font: NSFont, color: RGBA, lineSpacing: CGFloat = 0, paragraphSpacing: CGFloat = 0,
              hanging: String? = nil, maxLines: Int = 0, in r: CGRect) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return text(Self.attributed(string, font: font, color: color, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing, hanging: hanging),
                    maxLines: maxLines, in: r)
    }

    /// Writes a styled paragraph, same rules as above
    @discardableResult
    func text(_ attributed: NSAttributedString, maxLines: Int = 0, in r: CGRect) -> CGFloat {
        guard attributed.length > 0, r.width > 1, r.height > 1 else { return 0 }
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        var box = r
        if maxLines > 0 { box.size.height = min(r.height, Self.height(setter, maxLines: maxLines, width: r.width) + 1) }
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: flip(box), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        // Height actually used: the bottom edge of the last line
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return 0 }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(lines.last!, nil, &descent, nil)
        return box.height - origins.last!.y + descent
    }

    /// Badge: a small capsule on a card corner, top left by default, can go to the bottom and right edges
    func badges(_ labels: [String], w: CGFloat, bottom: Bool = false, trailing: Bool = false, color: RGBA = Palette.badge) {
        let font = NSFont.systemFont(ofSize: fontSize(w * CardType.badge), weight: .medium)
        let inset = w * 0.04, padX = w * 0.022, height = w * CardType.badge * 1.7
        var x = trailing ? size.width - inset : inset
        let y = bottom ? size.height - inset - height : inset
        for label in labels {
            let textWidth = NSAttributedString(string: label, attributes: [.font: font]).size().width
            let width = textWidth + padX * 2
            if trailing { x -= width }
            let pill = CGRect(x: x, y: y, width: width, height: height)
            ctx.setFillColor(color.cg)
            ctx.addPath(CGPath(roundedRect: flip(pill), cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
            ctx.fillPath()
            text(label, font: font, color: Palette.badgeInk, in: CGRect(x: x + padX, y: y + (height - font.ascender + font.descender) / 2 - 0.5, width: textWidth + 2, height: height))
            x += trailing ? -inset * 0.5 : width + inset * 0.5
        }
    }

    /// Video play marker: a translucent circle in the middle of the picture with a triangle inside
    func playMark(w: CGFloat) {
        let d = w * CardType.playMark
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        ctx.setFillColor(Palette.badge.cg)
        ctx.fillEllipse(in: flip(CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)))
        ctx.setStrokeColor(Palette.badgeInk.opacity(0.6).cg)
        ctx.setLineWidth(max(0.5, w * 0.004))
        ctx.strokeEllipse(in: flip(CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)))
        let t = d * 0.32
        ctx.setFillColor(Palette.badgeInk.cg)
        ctx.move(to: CGPoint(x: c.x - t * 0.7, y: size.height - (c.y - t)))
        ctx.addLine(to: CGPoint(x: c.x + t, y: size.height - c.y))
        ctx.addLine(to: CGPoint(x: c.x - t * 0.7, y: size.height - (c.y + t)))
        ctx.fillPath()
    }

    /// Audio waveform: a few vertical bars of different heights
    func waveform(in r: CGRect) {
        let heights: [CGFloat] = [0.3, 0.6, 1, 0.7, 0.45, 0.85, 0.5, 0.25]
        let bar = r.width / CGFloat(heights.count * 2 - 1)
        ctx.setFillColor(Palette.inkSecondary.now.cg)
        for (i, h) in heights.enumerated() {
            let height = r.height * h
            let b = CGRect(x: r.minX + CGFloat(i) * bar * 2, y: r.midY - height / 2, width: bar, height: height)
            ctx.addPath(CGPath(roundedRect: flip(b), cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
        }
        ctx.fillPath()
    }
}

extension RGBA {
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

extension Markdown.Style.Ink {
    /// Colors drawn on the card
    var cardColor: RGBA {
        switch self {
        case .primary: Palette.ink.now
        case .secondary: Palette.inkSecondary.now
        case .faint: Palette.inkTertiary.now
        case .link: Palette.accent
        }
    }
}
