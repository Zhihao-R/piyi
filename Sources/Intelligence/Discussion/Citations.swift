import Foundation
import Library

/// 回答里的引用：模型直接写在文字里，[c12·p3]、[c12·t4] 指卡的段落，[c12] 指整张卡，[r5·2] 指第 5 次工具调用读回的第 2 项。
/// 不用服务方专有的引用功能：换一家模型就没有
public enum Citations {
    /// 一处引用的写法
    nonisolated(unsafe) static let strict = #/c(\d+)(?:·([pt])(\d+))?|r(\d+)·(\d+)/#
    /// 方括号里以 c 或 r 加数字开头的都算模型想写引用：对得上写法的留下，写坏的整个去掉
    nonisolated(unsafe) static let bracket = #/\[([cr]\d+[^\[\]\n]{0,40})\]/#
    /// 连同前面的空格：去掉引用时空格一起去掉，不会剩下「压抑 。」
    nonisolated(unsafe) static let spaced = #/([ \t]*)\[([cr]\d+[^\[\]\n]{0,40})\]/#

    /// 检查要对照的：桌上（不在废纸篓里）的卡，和每次工具调用读回的几项（下标是第几次调用，从 1 数）
    public struct Sources: Sendable {
        public var cards: [Int64: (title: String, passages: [Passage])]
        public var results: [Int: [String]]

        public init(cards: [Int64: (title: String, passages: [Passage])], results: [Int: [String]]) {
            (self.cards, self.results) = (cards, results)
        }
    }

    /// 答完后逐个检查：卡不在桌上、段落不存在、工具结果没有这一项、格式写坏了，这个引用整个去掉。
    /// 通过的连同原话存下；一个方括号里写了几处（[c1·p2, c1·p3]）拆成几个
    public static func check(_ text: String, against sources: Sources) -> Answer {
        var citations: [Citation] = []
        let checked = text.replacing(spaced) { match in
            let refs = refs(in: match.2)
            let kept = refs.compactMap { resolve($0, sources) }
            guard kept.count == refs.count else { return "" }
            for c in kept where !citations.contains(where: { $0.ref == c.ref }) { citations.append(c) }
            return match.1 + kept.map { "[\($0.ref)]" }.joined()
        }
        // 去掉的引用原本写在括号里：空括号一起去掉
        return Answer(text: checked.replacing(#/[ \t]*[（(][ \t]*[)）]/#, with: ""), citations: citations)
    }

    /// 一个方括号里写的几处
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
        // 没有段落的卡（图片、截图）只能整张引用：模型给它标了段落号，卡没错，按整张算
        guard let part = m.2.flatMap({ Passage.Part(rawValue: String($0)) }), let number = m.3.flatMap({ Int($0) }), !source.passages.isEmpty else {
            return Citation(ref: "c\(card)", card: card, quote: source.title)
        }
        guard let passage = source.passages.first(where: { $0.part == part && $0.number == number }) else { return nil }
        return Citation(ref: ref, card: card, part: part, number: number, quote: passage.text, seconds: passage.seconds)
    }

    /// 回答切成文字和引用，界面按它画：引用画成小数字
    public enum Piece: Equatable, Sendable {
        case text(String)
        /// 引用的写法，不带方括号
        case cite(String)
    }

    /// 生成过程中也用它：写对了的引用直接显示成小数字；末尾还没写完的「[c12·」先藏起来，写坏的照原样留着，答完检查时去掉
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

    /// 去掉引用后的纯文字：收成文字卡、拷贝用
    public static func plain(_ text: String) -> String {
        text.replacing(spaced, with: "")
    }
}
