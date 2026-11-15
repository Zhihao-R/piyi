import Foundation

/// 卡片原文里能被引用的最小单位：正文的一段（p）、转录的一个时间段（t）。
/// 发给模型时怎么编号、放大查看里点了引用滚到哪，都按这一份切法
public struct Passage: Sendable, Equatable {
    public enum Part: String, Sendable, Codable {
        case body = "p", transcript = "t"
    }

    public var part: Part
    /// 从 1 数
    public var number: Int
    public var text: String
    /// 转录段开始的秒数
    public var seconds: Int?

    /// 引用里的写法：p3、t4
    public var label: String { part.rawValue + String(number) }
}

public enum Passages {
    /// 一张卡的全部段落：正文在前、转录在后。图片和截图没有段落，只能整张引用
    public static func of(_ card: Card) -> [Passage] {
        guard card.kind != .image else { return [] }
        // 先拿掉署名再去配图标记，和阅读页同一个顺序：署名只认开头十行，配图标记也算行
        let source = card.kind == .text ? card.text ?? card.body : card.body.map { Article.plain(credits(in: $0, for: card).body) }
        let body = lines(source ?? "").enumerated().map { Passage(part: .body, number: $0.offset + 1, text: $0.element) }
        let transcript = lines(card.transcript ?? "").enumerated().map { i, line in
            Passage(part: .transcript, number: i + 1, text: line, seconds: Player.chapters(in: line, duration: nil).first?.seconds)
        }
        return body + transcript
    }

    /// 一行一段，空行跳过
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 公众号开头几行里的署名拿出来（阅读页并成一行小字），其余文章不动
    public static func credits(in body: String, for card: Card) -> (credits: [String], body: String) {
        guard card.format == "公众号" else { return ([], body) }
        var credits: [String] = []
        let lines = body.components(separatedBy: "\n").enumerated().filter { i, line in
            guard i < 10, let credit = Article.credit(line) else { return true }
            credits.append(credit)
            return false
        }
        return (credits, lines.map(\.element).joined(separator: "\n"))
    }

    /// 按存下的原话在现在的正文里找回那一段：原文改过（重新抓取、补完转录）后编号会变，原话不变。
    /// 先找同样的一段，再找包含它（或被它包含）的一段；都没有返回 nil
    public static func find(_ quote: String, part: Passage.Part, in card: Card) -> Passage? {
        find(quote, part: part, among: of(card))
    }

    /// 同上，段落已经切好：一次要找好几处时只切一遍
    public static func find(_ quote: String, part: Passage.Part, among passages: [Passage]) -> Passage? {
        let quote = quote.trimmingCharacters(in: .whitespaces)
        guard !quote.isEmpty else { return nil }
        let candidates = passages.filter { $0.part == part }
        return candidates.first { $0.text == quote } ?? candidates.first { $0.text.contains(quote) || quote.contains($0.text) && $0.text.count >= 8 }
    }
}
