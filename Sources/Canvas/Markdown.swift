import AppKit
import Library

/// Markdown on cards: only the few kinds useful for jotting things down — headings, bold, italic, inline code, links, lists, quotes, code blocks.
/// One parse gives two looks: laid out (cards, detail view: markers removed) and editing (every character kept, markers faded), so what you see while writing is what you get
public enum Markdown {
    /// Which cards are laid out as Markdown: text cards you wrote, Markdown files. Collected text is kept verbatim, its asterisks and hash signs shown as they are
    public static func applies(to card: CardFace) -> Bool { card.form == .note || isDocument(kind: card.kind, format: card.format) }
    public static func applies(to card: Card) -> Bool { card.form == .note || isDocument(kind: card.kind, format: card.format) }
    private static func isDocument(kind: Kind, format: String?) -> Bool { kind == .document && format == "Markdown" }

    /// Font sizes are in points. Colors come from the caller: drawing cards uses fixed card colors, detail view follows the system light/dark mode
    public struct Style {
        public enum Ink { case primary, secondary, faint, link }
        public var body: CGFloat
        public var lineSpacing: CGFloat
        public var ink: (Ink) -> Any
        /// Round font sizes (to whole pixels when drawing cards, see Pen.fontSize)
        public var round: (CGFloat) -> CGFloat = { $0 }

        public init(body: CGFloat, lineSpacing: CGFloat, ink: @escaping (Ink) -> Any) {
            (self.body, self.lineSpacing, self.ink) = (body, lineSpacing, ink)
        }

        /// How much larger level one to three headings are than body text; deeper ones use level three
        static let headings: [CGFloat] = [1.5, 1.25, 1.1]

        func font(_ line: Line.Block, bold: Bool = false, italic: Bool = false, code: Bool = false) -> NSFont {
            if code || line == .code { return .monospacedSystemFont(ofSize: round(body * 0.9), weight: .regular) }
            var size = body, weight = NSFont.Weight.regular
            if case .heading(let level) = line { size = body * Self.headings[min(level, 3) - 1]; weight = .bold }
            let font = NSFont.systemFont(ofSize: round(size), weight: bold ? .bold : weight)
            return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        }
    }

    /// The laid-out look: markers removed, lists turned into bullets, code block fence lines take no space
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

    /// The editing look: identical to the source text (the text in the text box is the text saved), just with markers faded, headings larger, and bold bolder
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

    /// A Markdown file's title is already shown separately (extraction takes the first level-one heading): that line isn't repeated in the body
    public static func droppingTitle(_ title: String, from source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("# ") }),
              lines[i].dropFirst(2).trimmingCharacters(in: .whitespaces) == title else { return source }
        lines.remove(at: i)
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    // MARK: Parsing

    /// A line: which kind of block, where its line-start marker is, and what each run of inline text looks like. Positions are NSString indices, usable directly by the text box
    struct Line: Equatable {
        enum Block: Equatable { case paragraph, heading(Int), bullet(depth: Int), ordered(depth: Int), quote, code, fence }
        var block: Block
        /// The whole line, without the newline
        var range: NSRange
        /// Line-start marker: "# ", "- ", "1. ", "> "; length 0 when there is none
        var marker: NSRange
        /// The text after the line-start marker, cut into runs by style, end to end
        var spans: [Span]
    }

    struct Span: Equatable {
        var range: NSRange
        var bold = false, italic = false, code = false, link = false
        /// Inline markers (asterisks, backticks, link brackets and URLs): removed when laid out, faded when editing
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

    /// What kind of block the line starts, and how long the marker is (list indentation counts as part of the marker; every two spaces is one level deeper)
    private static func block(of line: String) -> (Line.Block, Int) {
        let range = NSRange(location: 0, length: (line as NSString).length)
        if let m = heading.firstMatch(in: line, range: range) { return (.heading(m.range(at: 1).length), m.range.length) }
        if let m = bullet.firstMatch(in: line, range: range) { return (.bullet(depth: m.range(at: 1).length / 2), m.range.length) }
        if let m = ordered.firstMatch(in: line, range: range) { return (.ordered(depth: m.range(at: 1).length / 2), m.range.length) }
        if let m = quote.firstMatch(in: line, range: range) { return (.quote, m.range.length) }
        return (.paragraph, 0)
    }

    /// The inline forms, recognized in order: code first (asterisks inside don't count), then links, bold, italic
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

    // Group 1 is the text to show; around it are the markers
    private static let codeSpan = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)\s]+\)"#)
    /// Three asterisks are bold and italic: recognized before bold, otherwise it would read as bold with a single asterisk left on each side
    private static let boldItalic = try! NSRegularExpression(pattern: #"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#)
    private static let boldStars = try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
    private static let boldUnderscores = try! NSRegularExpression(pattern: #"(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)"#)
    private static let italicStar = try! NSRegularExpression(pattern: #"(?<!\*)\*(?=[^\s*])([^*]+?)(?<=\S)\*(?!\*)"#)
    private static let italicUnderscore = try! NSRegularExpression(pattern: #"(?<!\w)_(?=\S)([^_]+?)(?<=\S)_(?!\w)"#)

    /// The text after the markers in a line, cut into runs of the same style. Each character records its own style, then adjacent runs with the same style are merged
    private static func spans(_ text: NSString, in range: NSRange) -> [Span] {
        guard range.length > 0 else { return [] }
        var marks = [Span](repeating: Span(range: NSRange()), count: range.length)
        let line = text.substring(with: range)
        let whole = NSRange(location: 0, length: range.length)
        for kind in Inline.allCases {
            for pattern in kind.patterns {
                for m in pattern.matches(in: line, range: whole) {
                    // Text inside code and markers doesn't take part in other forms
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
