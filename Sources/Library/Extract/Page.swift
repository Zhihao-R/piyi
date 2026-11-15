import Foundation

/// 抓下来的网页和几个读取方法
struct Page: Sendable {
    let html: String
    let url: URL

    init(html: String, url: URL) {
        self.html = html
        self.url = url
    }

    /// 按页面声明的编码解码（GBK 页面不少），否则宽松地按 UTF-8：截断在半个字上也不会整页变乱码
    init?(data: Data, url: URL) {
        let bytes = data.prefix(3_000_000)
        let head = String(decoding: bytes.prefix(2048), as: UTF8.self).lowercased()
        if head.contains("charset=gb") || head.contains("charset=\"gb") {
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            guard let html = String(data: bytes, encoding: gb) else { return nil }
            self.init(html: html, url: url)
        } else {
            self.init(html: String(decoding: bytes, as: UTF8.self), url: url)
        }
    }

    /// <meta property="og:title" content="…">，属性顺序不限；content 里可以有另一种引号（Don't）。
    /// 先一遍找出所有 meta 标签，再只在标签里面读属性：整页一个式子去匹配，碰上没有 content 的标签会一路扫到页尾，小页面也要几秒
    func meta(_ name: String) -> String? {
        for tag in html.allMatches(#"<meta\b[^>]*>"#) {
            guard tag.firstMatch(#"(?:property|name)\s*=\s*["']([^"']*)["']"#, group: 1)?.caseInsensitiveCompare(name) == .orderedSame,
                  let value = tag.firstMatch(#"content\s*=\s*"([^"]*)""#, group: 1) ?? tag.firstMatch(#"content\s*=\s*'([^']*)'"#, group: 1)
            else { continue }
            let decoded = Page.decode(value)
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }

    var title: String? {
        html.firstMatch(#"<title[^>]*>([^<]+)</title>"#, group: 1).map(Page.decode)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 网页里所有 <p> 段落的文字
    static func paragraphs(in html: String) -> String {
        withoutScripts(html).allMatches(#"<p[^>]*>([\s\S]*?)</p>"#)
            .map { decode($0.replacing(#/<[^>]+>/#, with: "")).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 1 }
            .joined(separator: "\n")
    }

    /// 正文按原顺序切成文字段和配图：块级标签（p、section、div…）之间的文字算一段，<img> 记下懒加载地址
    static func blocks(in html: String, image pattern: String) -> [Block] {
        var blocks: [Block] = [], text = ""
        func flush() {
            let line = decode(text).replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
            if line.count > 1 { blocks.append(.text(line)) }
            text = ""
        }
        // 逐个读标签和文字：块级标签断段，<img> 断段并记下图，行内标签（span、strong…）不断
        for token in withoutScripts(html).allMatches(#"<[^>]*>|[^<]+"#) {
            guard token.hasPrefix("<") else { text += token; continue }
            guard let name = token.firstMatch(#"^</?\s*([a-z0-9]+)"#, group: 1)?.lowercased() else { continue }
            if name == "img" {
                flush()
                if let url = token.firstMatch(pattern, group: 1) { blocks.append(.image(decode(url))) }
            } else if blockTags.contains(name) {
                flush()
            }
        }
        flush()
        return blocks
    }

    private static let blockTags: Set = ["p", "section", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "br", "hr",
                                         "figure", "figcaption", "pre", "table", "tr", "td"]

    enum Block: Equatable { case text(String), image(String) }

    private static func withoutScripts(_ html: String) -> String {
        html.replacing(#/<(script|style)[\s\S]*?</\1>/#.ignoresCase(), with: "")
    }

    static func decode(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&mdash;", "—")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.replacing(#/&#(\d+);/#) { match in
            String(UnicodeScalar(UInt32(match.output.1) ?? 32).map(Character.init) ?? " ")
        }
    }
}

extension String {
    func firstMatch(_ pattern: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let range = Range(match.range(at: group), in: self) else { return nil }
        return String(self[range])
    }

    func allMatches(_ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { match in
            Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: self).map { String(self[$0]) }
        }
    }
}
