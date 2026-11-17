import Foundation

/// The smallest citable unit of a card's original text: a paragraph of the body (p), a time segment of the transcript (t).
/// How passages are numbered for the model, and where clicking a citation scrolls to in the detail view, all follow this one split
public struct Passage: Sendable, Equatable {
    public enum Part: String, Sendable, Codable {
        case body = "p", transcript = "t"
    }

    public var part: Part
    /// Counted from 1
    public var number: Int
    public var text: String
    /// Start second of the transcript segment
    public var seconds: Int?

    /// How it's written in a citation: p3, t4
    public var label: String { part.rawValue + String(number) }
}

public enum Passages {
    /// All passages of a card: body first, transcript after. Images and screenshots have no passages and can only be cited whole
    public static func of(_ card: Card) -> [Passage] {
        guard card.kind != .image else { return [] }
        // Take out the byline first, then the image markers, in the same order as the reading page: bylines are only recognized in the first ten lines, and image markers count as lines
        let source = card.kind == .text ? card.text ?? card.body : card.body.map { Article.plain(credits(in: $0, for: card).body) }
        let body = lines(source ?? "").enumerated().map { Passage(part: .body, number: $0.offset + 1, text: $0.element) }
        let transcript = lines(card.transcript ?? "").enumerated().map { i, line in
            Passage(part: .transcript, number: i + 1, text: line, seconds: Player.chapters(in: line, duration: nil).first?.seconds)
        }
        return body + transcript
    }

    /// One line per passage, skipping blank lines
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Pull the byline out of the first few lines of a WeChat Official Accounts article (the reading page merges it into one line of small text); other articles are left alone
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

    /// Find a passage in the current body by its saved words: numbering changes after the text changes (refetched, transcript completed), the words don't.
    /// First look for an identical passage, then one that contains it (or is contained by it); nil if neither
    public static func find(_ quote: String, part: Passage.Part, in card: Card) -> Passage? {
        find(quote, part: part, among: of(card))
    }

    /// Same as above with passages already split: split only once when looking up several
    public static func find(_ quote: String, part: Passage.Part, among passages: [Passage]) -> Passage? {
        let quote = quote.trimmingCharacters(in: .whitespaces)
        guard !quote.isEmpty else { return nil }
        let candidates = passages.filter { $0.part == part }
        return candidates.first { $0.text == quote } ?? candidates.first { $0.text.contains(quote) || quote.contains($0.text) && $0.text.count >= 8 }
    }
}
