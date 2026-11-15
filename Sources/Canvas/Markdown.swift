import AppKit
import Library

/// 卡片上的 Markdown：只认随手写字用得到的几种——标题、粗体、斜体、行内代码、链接、列表、引用、代码块。
/// 同一份解析出两种样子：排好的（卡片、放大查看：标记去掉）和编辑时的（字一个不少，标记变淡），所以边写边看到的就是写完的样子
public enum Markdown {
    /// 哪些卡按 Markdown 排：你写的文字卡、Markdown 文件。收进来的文字是原话，里面的星号、井号照原样显示
    public static func applies(to card: CardFace) -> Bool { card.form == .note || isDocument(kind: card.kind, format: card.format) }
    public static func applies(to card: Card) -> Bool { card.form == .note || isDocument(kind: card.kind, format: card.format) }
    private static func isDocument(kind: Kind, format: String?) -> Bool { kind == .document && format == "Markdown" }

    /// 字号是点。颜色由调用方给：画卡片用固定的卡片颜色，放大查看跟着系统深浅色
    public struct Style {
        public enum Ink { case primary, secondary, faint, link }
        public var body: CGFloat
        public var lineSpacing: CGFloat
        public var ink: (Ink) -> Any
        /// 字号取整（画卡片时取到整像素，见 Pen.fontSize）
        public var round: (CGFloat) -> CGFloat = { $0 }

        public init(body: CGFloat, lineSpacing: CGFloat, ink: @escaping (Ink) -> Any) {
            (self.body, self.lineSpacing, self.ink) = (body, lineSpacing, ink)
        }

        /// 一级到三级标题比正文大多少，更深的按三级
        static let headings: [CGFloat] = [1.5, 1.25, 1.1]

        func font(_ line: Line.Block, bold: Bool = false, italic: Bool = false, code: Bool = false) -> NSFont {
            if code || line == .code { return .monospacedSystemFont(ofSize: round(body * 0.9), weight: .regular) }
            var size = body, weight = NSFont.Weight.regular
            if case .heading(let level) = line { size = body * Self.headings[min(level, 3) - 1]; weight = .bold }
            let font = NSFont.systemFont(ofSize: round(size), weight: bold ? .bold : weight)
            return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        }
    }

    /// 排好的样子：标记去掉，列表换成圆点，代码块的围栏行不占地方
    public static func rendered(_ source: String, style: Style) -> NSAttributedString {
        let text = source as NSString, out = NSMutableAttributedString()
        var first = true
        for line in parse(source) where line.block != .fence {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = style.lineSpacing
            paragraph.paragraphSpacingBefore = if case .heading = line.block, !first { style.body * 0.4 } else { 0 }
            let base = style.font(line.block)
            var lead = ""
            switch line.block {
            case .bullet(let depth), .ordered(let depth):
                let indent = CGFloat(depth) * style.body * 1.2
                lead = if case .ordered = line.block { text.substring(with: line.marker).trimmingCharacters(in: .whitespaces) + " " } else { "• " }
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + (lead as NSString).size(withAttributes: [.font: base]).width
            case .quote:
                paragraph.firstLineHeadIndent = style.body * 0.8
                paragraph.headIndent = style.body * 0.8
            default: break
            }
            let color = style.ink(line.block == .quote || line.block == .code ? .secondary : .primary)
            if !first { out.append(NSAttributedString(string: "\n", attributes: [.font: base, .paragraphStyle: paragraph])) }
            first = false
            out.append(NSAttributedString(string: lead, attributes: [.font: base, .foregroundColor: color, .paragraphStyle: paragraph]))
            for span in line.spans where !span.marker {
                out.append(NSAttributedString(string: text.substring(with: span.range), attributes: [
                    .font: style.font(line.block, bold: span.bold, italic: span.italic, code: span.code),
                    .foregroundColor: span.link ? style.ink(.link) : span.code && line.block != .code ? style.ink(.secondary) : color,
                    .paragraphStyle: paragraph,
                ]))
            }
        }
        return out
    }

    /// 编辑时的样子：和原文一字不差（文本框里的字就是存下来的字），只是标记变淡、标题变大、粗体变粗
    public static func styled(_ source: String, style: Style) -> NSAttributedString {
        let out = NSMutableAttributedString(string: source)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        out.addAttributes([.font: style.font(.paragraph), .foregroundColor: style.ink(.primary), .paragraphStyle: paragraph],
                          range: NSRange(location: 0, length: out.length))
        for line in parse(source) {
            let color = style.ink(line.block == .fence ? .faint : line.block == .quote || line.block == .code ? .secondary : .primary)
            out.addAttributes([.font: style.font(line.block), .foregroundColor: line.block == .fence ? style.ink(.faint) : color], range: line.range)
            out.addAttribute(.foregroundColor, value: style.ink(.faint), range: line.marker)
            for span in line.spans {
                out.addAttributes([
                    .font: style.font(line.block, bold: span.bold, italic: span.italic, code: span.code),
                    .foregroundColor: span.marker ? style.ink(.faint) : span.link ? style.ink(.link) : color,
                ], range: span.range)
            }
        }
        return out
    }

    /// Markdown 文件的标题已经单独显示（抽取时取第一个一级标题）：正文里那一行不再重复
    public static func droppingTitle(_ title: String, from source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("# ") }),
              lines[i].dropFirst(2).trimmingCharacters(in: .whitespaces) == title else { return source }
        lines.remove(at: i)
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    // MARK: 解析

    /// 一行：哪种块、行首标记在哪、行内的字一段段是什么样子。位置都按 NSString 的下标，文本框直接能用
    struct Line: Equatable {
        enum Block: Equatable { case paragraph, heading(Int), bullet(depth: Int), ordered(depth: Int), quote, code, fence }
        var block: Block
        /// 整行，不含换行
        var range: NSRange
        /// 行首标记：「# 」「- 」「1. 」「> 」；没有时长度为 0
        var marker: NSRange
        /// 行首标记之后的字，按样式切成段，首尾相接
        var spans: [Span]
    }

    struct Span: Equatable {
        var range: NSRange
        var bold = false, italic = false, code = false, link = false
        /// 行内标记（星号、反引号、链接的方括号和网址）：排好时去掉，编辑时变淡
        var marker = false
    }

    static func parse(_ source: String) -> [Line] {
        let text = source as NSString
        var lines: [Line] = [], inCode = false, start = 0
        while start <= text.length {
            let end = text.range(of: "\n", range: NSRange(location: start, length: text.length - start)).location
            let range = NSRange(location: start, length: (end == NSNotFound ? text.length : end) - start)
            let line = text.substring(with: range)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                lines.append(Line(block: .fence, range: range, marker: NSRange(location: start, length: 0), spans: []))
            } else if inCode {
                lines.append(Line(block: .code, range: range, marker: NSRange(location: start, length: 0), spans: [Span(range: range, code: true)]))
            } else {
                let (block, markerLength) = Self.block(of: line)
                let marker = NSRange(location: start, length: markerLength)
                lines.append(Line(block: block, range: range, marker: marker,
                                  spans: spans(text, in: NSRange(location: marker.upperBound, length: range.upperBound - marker.upperBound))))
            }
            guard end != NSNotFound else { break }
            start = end + 1
        }
        return lines
    }

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^( *)[-*+]\s+"#)
    private static let ordered = try! NSRegularExpression(pattern: #"^( *)\d{1,3}[.)]\s+"#)
    private static let quote = try! NSRegularExpression(pattern: #"^>\s?"#)

    /// 行首是哪种块、标记多长（列表的缩进算在标记里，每两个空格深一层）
    private static func block(of line: String) -> (Line.Block, Int) {
        let range = NSRange(location: 0, length: (line as NSString).length)
        if let m = heading.firstMatch(in: line, range: range) { return (.heading(m.range(at: 1).length), m.range.length) }
        if let m = bullet.firstMatch(in: line, range: range) { return (.bullet(depth: m.range(at: 1).length / 2), m.range.length) }
        if let m = ordered.firstMatch(in: line, range: range) { return (.ordered(depth: m.range(at: 1).length / 2), m.range.length) }
        if let m = quote.firstMatch(in: line, range: range) { return (.quote, m.range.length) }
        return (.paragraph, 0)
    }

    /// 行内的几种写法，按先后认：先认代码（里面的星号不算数），再认链接、粗体、斜体
    private enum Inline: CaseIterable {
        case code, link, bold, italic

        var patterns: [NSRegularExpression] {
            switch self {
            case .code: [Markdown.codeSpan]
            case .link: [Markdown.link]
            case .bold: [Markdown.boldItalic, Markdown.boldStars, Markdown.boldUnderscores]
            case .italic: [Markdown.italicStar, Markdown.italicUnderscore]
            }
        }
    }

    // 第 1 组是要显示的字，前后是标记
    private static let codeSpan = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)\s]+\)"#)
    /// 三个星号又粗又斜：排在粗体前面认，否则会被认成粗体、剩下两边各一个星号
    private static let boldItalic = try! NSRegularExpression(pattern: #"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#)
    private static let boldStars = try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
    private static let boldUnderscores = try! NSRegularExpression(pattern: #"(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)"#)
    private static let italicStar = try! NSRegularExpression(pattern: #"(?<!\*)\*(?=[^\s*])([^*]+?)(?<=\S)\*(?!\*)"#)
    private static let italicUnderscore = try! NSRegularExpression(pattern: #"(?<!\w)_(?=\S)([^_]+?)(?<=\S)_(?!\w)"#)

    /// 一行里标记之后的字，切成样式相同的几段。每个字记着自己的样式，再把相邻样式相同的并起来
    private static func spans(_ text: NSString, in range: NSRange) -> [Span] {
        guard range.length > 0 else { return [] }
        var marks = [Span](repeating: Span(range: NSRange()), count: range.length)
        let line = text.substring(with: range)
        let whole = NSRange(location: 0, length: range.length)
        for kind in Inline.allCases {
            for pattern in kind.patterns {
                for m in pattern.matches(in: line, range: whole) {
                    // 代码和标记里的字不再参加别的写法
                    guard !(m.range.location..<m.range.upperBound).contains(where: { marks[$0].code || marks[$0].marker }) else { continue }
                    let content = m.range(at: 1)
                    for i in m.range.location..<m.range.upperBound {
                        if !(content.location..<content.upperBound).contains(i) { marks[i].marker = true }
                        switch kind {
                        case .code: marks[i].code = true
                        case .link: marks[i].link = true
                        case .bold:
                            marks[i].bold = true
                            if pattern === Markdown.boldItalic { marks[i].italic = true }
                        case .italic: marks[i].italic = true
                        }
                    }
                }
            }
        }
        var out: [Span] = []
        for (i, var mark) in marks.enumerated() {
            mark.range = NSRange(location: range.location + i, length: 1)
            if var last = out.last, last.sameStyle(as: mark) {
                last.range.length += 1
                out[out.count - 1] = last
            } else {
                out.append(mark)
            }
        }
        return out
    }
}

private extension Markdown.Span {
    func sameStyle(as other: Self) -> Bool {
        (bold, italic, code, link, marker) == (other.bold, other.italic, other.code, other.link, other.marker)
    }
}
