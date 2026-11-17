import Foundation
import Library

/// Citations in an answer: the model writes them right in the text. [c12·p3], [c12·t4] point to a card's paragraph, [c12] to the whole card, [r5·2] to item 2 returned by the 5th tool call.
/// We don't use a provider's own citation feature: switch models and it's gone
public enum Citations {
    /// How one citation is written
    nonisolated(unsafe) static let strict = #/c(\d+)(?:·([pt])(\d+))?|r(\d+)·(\d+)/#
    /// Anything in square brackets starting with c or r plus a digit counts as the model trying to cite: well-formed ones stay, malformed ones are removed entirely
    nonisolated(unsafe) static let bracket = #/\[([cr]\d+[^\[\]\n]{0,40})\]/#
    /// Includes the space before it: removing a citation removes the space too, so nothing like "gloomy ." is left
    nonisolated(unsafe) static let spaced = #/([ \t]*)\[([cr]\d+[^\[\]\n]{0,40})\]/#

    /// What gets checked against: cards on the desk (not in the trash), and the items each tool call returned (indexed by call number, counting from 1)
    public struct Sources: Sendable {
        public var cards: [Int64: (title: String, passages: [Passage])]
        public var results: [Int: [String]]

        public init(cards: [Int64: (title: String, passages: [Passage])], results: [Int: [String]]) {
            (self.cards, self.results) = (cards, results)
        }
    }

    /// After answering, check each one: card not on the desk, paragraph doesn't exist, tool result has no such item, or malformed — the citation is removed entirely.
    /// The ones that pass are stored with the quoted text; several in one bracket ([c1·p2, c1·p3]) are split into several
    public static func check(_ text: String, against sources: Sources) -> Answer {
        var citations: [Citation] = []
        let checked = text.replacing(spaced) { match in
            let refs = refs(in: match.2)
            let kept = refs.compactMap { resolve($0, sources) }
            guard kept.count == refs.count else { return "" }
            for c in kept where !citations.contains(where: { $0.ref == c.ref }) { citations.append(c) }
            return match.1 + kept.map { "[\($0.ref)]" }.joined()
        }
        // The removed citation was inside parentheses: remove the empty parentheses too
        return Answer(text: checked.replacing(#/[ \t]*[（(][ \t]*[)）]/#, with: ""), citations: citations)
    }

    /// The several places written in one bracket
    static func refs(in bracket: Substring) -> [String] {
        bracket.split(whereSeparator: { ",，;；、 ".contains($0) }).map(String.init)
    }

    static func resolve(_ ref: String, _ sources: Sources) -> Citation? {
        guard let m = ref.wholeMatch(of: strict) else { return nil }
        if let call = m.4.flatMap({ Int($0) }), let item = m.5.flatMap({ Int($0) }) {
            guard let items = sources.results[call], items.indices.contains(item - 1) else { return nil }
            return Citation(ref: ref, call: call, item: item, quote: items[item - 1])
        }
        guard let card = m.1.flatMap({ Int64($0) }), let source = sources.cards[card] else { return nil }
        // A card without paragraphs (image, screenshot) can only be cited whole: the model gave it a paragraph number, but the card is right, so count it as the whole card
        guard let part = m.2.flatMap({ Passage.Part(rawValue: String($0)) }), let number = m.3.flatMap({ Int($0) }), !source.passages.isEmpty else {
            return Citation(ref: "c\(card)", card: card, quote: source.title)
        }
        guard let passage = source.passages.first(where: { $0.part == part && $0.number == number }) else { return nil }
        return Citation(ref: ref, card: card, part: part, number: number, quote: passage.text, seconds: passage.seconds)
    }

    /// The answer split into text and citations, which the interface draws: citations become small numbers
    public enum Piece: Equatable, Sendable {
        case text(String)
        /// How the citation is written, without square brackets
        case cite(String)
    }

    /// Also used while generating: well-formed citations show as small numbers right away; an unfinished "[c12·" at the end is hidden for now, malformed ones stay as is and are removed in the check after answering
    public static func pieces(_ text: String, streaming: Bool = false) -> [Piece] {
        var shown = Substring(text)
        if streaming, let open = shown.lastIndex(of: "["), !shown[open...].contains("]"),
           shown[shown.index(after: open)...].allSatisfy({ !$0.isNewline }) {
            shown = shown[..<open]
        }
        var pieces: [Piece] = [], rest = shown
        while let m = rest.firstMatch(of: bracket) {
            let refs = refs(in: m.1)
            guard refs.allSatisfy({ $0.wholeMatch(of: strict) != nil }) else {
                append(.text(String(rest[..<m.range.upperBound])), to: &pieces)
                rest = rest[m.range.upperBound...]
                continue
            }
            append(.text(String(rest[..<m.range.lowerBound])), to: &pieces)
            pieces += refs.map(Piece.cite)
            rest = rest[m.range.upperBound...]
        }
        append(.text(String(rest)), to: &pieces)
        return pieces
    }

    private static func append(_ piece: Piece, to pieces: inout [Piece]) {
        guard case .text(let new) = piece, !new.isEmpty else { return }
        if case .text(let last)? = pieces.last { pieces[pieces.count - 1] = .text(last + new) } else { pieces.append(piece) }
    }

    /// Plain text with citations removed: for collecting as a text card and for copying
    public static func plain(_ text: String) -> String {
        text.replacing(spaced, with: "")
    }
}
