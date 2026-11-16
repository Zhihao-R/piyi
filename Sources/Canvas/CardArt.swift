import AppKit
import CoreText
import Library
import Tokens

/// 卡片外观：在后台把一张卡画成一张位图。一条记录一张干净的卡片，外观上的每一处差异都表达一项信息（类型、格式、状态）。
/// 版式数值都相对卡片宽度（Tokens.CardType），卡片放大缩小时版式不变。
struct CardArt {
    let face: Face
    let size: CGSize
    /// 封面已经按裁剪框取好、解码成合适的大小；没有封面时为 nil
    let cover: CGImage?
    /// 聚拢时临时放大的倍数
    var zoom: CGFloat = 1
    /// 分拣放进来、你还没看过：右上角标「新」
    var unseen = false

    /// 画成 size × pixelScale 像素的位图
    func render(pixelScale: CGFloat) -> CGImage? {
        let w = Int((size.width * pixelScale).rounded(.up)), h = Int((size.height * pixelScale).rounded(.up))
        guard let ctx = screenBitmap(width: w, height: h) else { return nil }
        // 宽高各自取整后按实际像素铺满：只按 pixelScale 缩放的话，取整多出的那不到一像素留成空行，在卡片顶边显成一道白边
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        var pen = Pen(ctx: ctx, size: size, pixelScale: pixelScale)
        switch face {
        case .card(let card): draw(card, &pen)
        case .entry(_, let name, _): entry(name, &pen)
        }
        return ctx.makeImage()
    }

    private var w: CGFloat { size.width }
    /// 字号、边距按这个宽度算。文字类卡片固定按默认宽度：拉大只是排版区域变大，字号不变；其余卡片按实际宽度，整体缩放
    private var t: CGFloat { Self.reflows(face) ? CardSize.typeWidth * zoom : w }

    /// 文字类卡片（文字、文章，没有封面的网页和文档）：拉大时重新排版，不整体放大
    static func reflows(_ face: Face) -> Bool {
        guard case .card(let card) = face else { return false }
        return card.kind == .text || isArticle(card) || (card.kind == .web || card.kind == .document) && card.cover == nil
    }

    /// 有封面、有正文的网页：封面压标题，下面要点和正文。只看抽取出的正文，模型写的一句描述不算
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
            // 有平台角标（公众号、小红书）时底部写作者，没有时写网站
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
            pen.fill(Palette.media)
            if let cover { pen.image(cover, in: pen.bounds) }
            pen.playMark(w: t)
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

    /// 音频卡上声波占的那一块（相对卡片宽高）。播放钮摆在它正中（见 CanvasView.playButtons）
    static let waveform = CGRect(x: 0.3, y: 0.18, width: 0.4, height: 0.32)

    /// 短文：引文卡，宋体 / 衬线，留白多
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

    /// 你写的文字卡：底色是你挑的，Markdown 排好；排不下的底部渐隐
    private func note(_ card: CardFace, _ pen: inout Pen) {
        let paper = Palette.tint(card.tint).now
        pen.fill(paper)
        let p = t * CardType.padding, bottom = size.height - p
        pen.text(Markdown.rendered(card.excerpt, style: Self.noteStyle(t: t, round: pen.fontSize) { $0.cg }), in: CGRect(x: p, y: p, width: w - p * 2, height: bottom - p))
        pen.fade(paper, from: bottom - t * 0.12, to: bottom)
    }

    /// 文字卡的版式：画卡片和编辑时同一套，只是颜色的写法不同
    static func noteStyle(t: CGFloat, round: @escaping (CGFloat) -> CGFloat = { $0 }, ink: @escaping (RGBA) -> Any) -> Markdown.Style {
        var style = Markdown.Style(body: t * CardType.note, lineSpacing: t * CardType.bodyLineSpacing) { ink($0.cardColor) }
        style.round = round
        return style
    }

    /// 长文、没有图的网页和文档：标题 + 开头几段，底部渐隐 + 一行出处
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

    /// 有封面的文章：标题压在封面底部，下面先要点、再正文。拉大时封面只跟着变宽，多出的高度都用来露出更多字
    private func reading(_ cover: CGImage, _ card: CardFace, footer: String?, _ pen: inout Pen) {
        pen.fill(Palette.card.now)
        let p = t * CardType.padding
        let titleSize = t * CardType.title
        let titleHeight = pen.height(card.title, font: .systemFont(ofSize: pen.fontSize(titleSize), weight: .bold), maxLines: 3, width: w - p * 2)
        // 封面至少要放得下标题，上面再留出角标的位置
        let coverHeight = max(min(w * CardSize.coverShare(CGFloat(cover.height) / CGFloat(cover.width)), size.height * 0.6),
                              titleHeight + p * 2 + t * CardType.badge * 2.4)
        pen.image(cover, in: CGRect(x: 0, y: 0, width: w, height: coverHeight))
        let titleTop = coverHeight - p - titleHeight
        pen.fade(Palette.coverShade, from: max(0, titleTop - p * 2), to: coverHeight)
        pen.text(card.title, size: titleSize, weight: .bold, color: Palette.badgeInk,
                 in: CGRect(x: p, y: titleTop, width: w - p * 2, height: titleHeight + 1))

        let bottom = size.height - p - t * CardType.footer * 1.8
        var y = coverHeight + p * 0.9
        let column = { (y: CGFloat) in CGRect(x: p, y: y, width: w - p * 2, height: max(0, bottom - y)) }
        if let summary = card.summary {
            y += pen.text(summary, size: t * CardType.body, color: Palette.ink.now, lineSpacing: t * CardType.bodyLineSpacing,
                          paragraphSpacing: t * CardType.pointSpacing, hanging: "· ", in: column(y)) + t * CardType.gap
        }
        if card.excerpt != card.title {
            pen.text(card.excerpt, size: t * CardType.body, color: Palette.inkSecondary.now, lineSpacing: t * CardType.bodyLineSpacing, in: column(y))
        }
        pen.fade(Palette.card.now, from: bottom - t * 0.18, to: bottom)
        pen.text(footer ?? "", size: t * CardType.footer, color: Palette.inkTertiary.now, in: footerRect)
    }

    /// 有封面、没有正文的网页：封面 + 下面一栏标题和网站
    private func withCover(_ cover: CGImage, _ card: CardFace, footer: String?, _ pen: inout Pen) {
        pen.fill(Palette.card.now)
        let p = t * CardType.padding
        let bar = min(size.height * 0.45, w * 0.34)
        pen.image(cover, in: CGRect(x: 0, y: 0, width: w, height: size.height - bar))
        pen.text(card.title, size: t * CardType.title, weight: .bold, color: Palette.ink.now, maxLines: 2,
                 in: CGRect(x: p, y: size.height - bar + p * 0.8, width: w - p * 2, height: bar - p * 0.8 - t * CardType.footer * 1.8))
        pen.text(footer ?? "", size: t * CardType.footer, color: Palette.inkTertiary.now, in: footerRect)
    }

    /// 画板入口：画板名，下面一行「画板」
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

    /// 正在抽取、残缺、正在理解：一种轻量的标示
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

/// 画卡片用的笔：坐标都是左上角为原点、y 向下的点（卡片的世界坐标单位），内部换成 Core Graphics 的左下原点
struct Pen {
    let ctx: CGContext
    let size: CGSize
    let pixelScale: CGFloat
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    /// 字号取整到整像素：版式按卡片宽度连续变化，不取整的话几乎每张卡一个字号，
    /// 系统为每个字号单独缓存字形，5000 张卡时多占几十 MB
    func fontSize(_ points: CGFloat) -> CGFloat { max(1, (points * pixelScale).rounded()) / pixelScale }

    /// 左上原点的矩形 → Core Graphics 的矩形
    private func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }

    func fill(_ color: RGBA) { rect(bounds, color) }

    func rect(_ r: CGRect, _ color: RGBA) {
        ctx.setFillColor(color.cg)
        ctx.fill(flip(r))
    }

    /// 图片铺满矩形，多出来的部分裁掉（按顶边对齐：长图只露开头）
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

    /// 从 from 到 to 渐隐成底色（盖住被截断的正文）
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

    /// 写一段字，从矩形顶部开始排，排不下的截掉。返回实际占用的高度。
    /// hanging：每段开头的项目符号，折行时后面的行和符号后的字对齐
    @discardableResult
    func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: RGBA, lineSpacing: CGFloat = 0,
              paragraphSpacing: CGFloat = 0, hanging: String? = nil, maxLines: Int = 0, in r: CGRect) -> CGFloat {
        text(string, font: .systemFont(ofSize: fontSize(size), weight: weight), color: color, lineSpacing: lineSpacing,
             paragraphSpacing: paragraphSpacing, hanging: hanging, maxLines: maxLines, in: r)
    }

    /// 只量不画：排进这么宽、最多 maxLines 行要多高
    func height(_ string: String, font: NSFont, maxLines: Int, width: CGFloat) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return Self.height(CTFramesetterCreateWithAttributedString(Self.attributed(string, font: font, color: Palette.ink.now)), maxLines: maxLines, width: width)
    }

    /// 按实际排出的前 maxLines 行量高度：中文字体的行高比系统字体的标称值高，按标称值估会少排一行
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

    /// 写一段排好样式的字，规则同上
    @discardableResult
    func text(_ attributed: NSAttributedString, maxLines: Int = 0, in r: CGRect) -> CGFloat {
        guard attributed.length > 0, r.width > 1, r.height > 1 else { return 0 }
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        var box = r
        if maxLines > 0 { box.size.height = min(r.height, Self.height(setter, maxLines: maxLines, width: r.width) + 1) }
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: flip(box), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        // 实际用了多高：最后一行的底边
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return 0 }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(lines.last!, nil, &descent, nil)
        return box.height - origins.last!.y + descent
    }

    /// 角标：压在卡片角上的小胶囊，默认左上，可放到底边和右边
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

    /// 视频的播放标记：画面中间一个半透明圆，里面一个三角
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

    /// 音频的声波：几根高低不同的竖条
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
    /// 画在卡片上的颜色
    var cardColor: RGBA {
        switch self {
        case .primary: Palette.ink.now
        case .secondary: Palette.inkSecondary.now
        case .faint: Palette.inkTertiary.now
        case .link: Palette.accent
        }
    }
}
