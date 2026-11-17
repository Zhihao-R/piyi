import Foundation
import Library

/// A capability the AI can call while answering. The discussion kernel doesn't know specific tools, only this description: adding a tool is just writing one more
public protocol Tool: Sendable {
    /// For the model: English name, when to use it, parameter format
    var spec: ToolSpec { get }
    /// The name shown to you: "Find cards"
    var title: String { get }
    var nature: ToolNature { get }
    /// Takes the parameters the model filled in (JSON) and runs. desk is the cards currently on the desk. Throw on error; the kernel writes "didn't succeed" for it
    func run(_ arguments: String, desk: Set<Int64>) async throws -> ToolOutput
}

/// Read-only ones run directly; ones that change data are laid out as a proposal first and run only when you click (the first version has no data-changing tools)
public enum ToolNature: Sendable { case reading, changing }

public struct ToolOutput: Sendable {
    /// Text handed to the model; the kernel truncates it to 4000 characters
    public var text: String
    /// What follows the colon in the gray line in the conversation: "context management" in "Find cards: context management"
    public var detail: String
    /// The items that can be cited
    public var items: [String] = []
    public var shown: ToolResult.Shown?
    /// Extra money spent (USD)
    public var cost = 0.0

    public init(text: String, detail: String, items: [String] = [], shown: ToolResult.Shown? = nil, cost: Double = 0) {
        (self.text, self.detail, self.items, self.shown, self.cost) = (text, detail, items, shown, cost)
    }
}

/// The parameters the model filled in aren't in the agreed format
struct BadArguments: LocalizedError {
    var errorDescription: String? { String(localized: "参数格式不对") }
}

/// Find cards: the parameters are the search conditions themselves, used to build a query for Searcher.find. Search doesn't re-understand the sentence: the model in the discussion already did, and doing it again costs about 3 more seconds.
/// What's found are candidate cards: not yet on the desk, only laid out for you to pick from, and can't be cited as evidence
public struct FindCards: Tool {
    let searcher: Searcher
    /// At most how many to return
    static let limit = 8

    public init(searcher: Searcher) { self.searcher = searcher }

    public let title = String(localized: "找卡")
    public let nature = ToolNature.reading

    public var spec: ToolSpec {
        ToolSpec(name: "find_cards", description: "在用户的收藏里找卡片。用户引用的卡里没有需要的、或者用户想找收过的类似内容时用。找到的卡用户还没引用，不能当出处，只能建议用户引用。", parameters: """
            {"type":"object","properties":{\
            "text":{"type":"string","description":"要找的内容，一句话描述"},\
            "kinds":{"type":"array","items":{"type":"string","enum":[\(Kind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]},"description":"只找这几类"},\
            "days":{"type":"integer","description":"只找最近几天收的"},\
            "color":{"type":"string","enum":[\(ColorName.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ","))],"description":"画面的主要颜色"}},\
            "required":["text"]}
            """)
    }

    struct Arguments: Decodable {
        var text: String
        var kinds: [Kind]?
        var days: Int?
        var color: ColorName?
    }

    public func run(_ arguments: String, desk: Set<Int64>) async throws -> ToolOutput {
        guard let a = try? JSONDecoder().decode(Arguments.self, from: Data(arguments.utf8)) else { throw BadArguments() }
        var q = Query(text: a.text)
        q.lookFor(a.text)
        q.kinds = Set(a.kinds ?? [])
        q.days = a.days
        q.colors = a.color.map { [$0] } ?? []
        // Cards already on the desk aren't candidates: the model already has their original text
        let found = Array(await searcher.find(q, online: true).filter { !desk.contains($0) }.prefix(Self.limit))
        // Stopped: search doesn't throw, so add it here so a half-finished result isn't mistaken for "nothing found"
        try Task.checkCancellation()
        let briefs = Dictionary(uniqueKeysWithValues: await searcher.snapshot().map { ($0.id, $0.brief) })
        let lines = found.compactMap { id in briefs[id].map { "c\(id) \($0)" } }
        let text = lines.isEmpty ? "没找到相关的卡。"
            : "找到 \(lines.count) 张候选卡。用户还没引用它们，不能当出处；需要的话建议用户引用：\n" + lines.joined(separator: "\n")
        return ToolOutput(text: text, detail: a.text, shown: found.isEmpty ? nil : .cards(found))
    }
}

/// Draw random cards: the model searches by meaning but never leaves things to chance, which is exactly what "draw one and interpret it for me" or "pick a few at random for me to look at" need.
/// With this tool, the model understands such requests itself; no need to write a rule for every phrasing.
/// Drawn cards are candidates just like those from Find cards: laid out for you to pick from, and can't be cited as evidence
public struct PickRandomCards: Tool {
    let searcher: Searcher
    /// At most how many to draw at once
    static let limit = 5

    public init(searcher: Searcher) { self.searcher = searcher }

    public let title = String(localized: "随机抽卡")
    public let nature = ToolNature.reading

    public var spec: ToolSpec {
        ToolSpec(name: "pick_random_cards", description: "从用户的收藏里随机抽几张卡。用户想抽一张、碰碰运气、随便看看，或者要几张没有指定内容的卡时用；要找特定内容的卡用 find_cards。抽到的卡用户还没引用，不能当出处，提到时写卡名。", parameters: """
            {"type":"object","properties":{\
            "count":{"type":"integer","description":"抽几张，1 到 \(Self.limit)，不写就是 1"},\
            "kinds":{"type":"array","items":{"type":"string","enum":[\(Kind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]},"description":"只在这几类里抽"},\
            "days":{"type":"integer","description":"只在最近几天收的里抽"},\
            "color":{"type":"string","enum":[\(ColorName.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ","))],"description":"画面的主要颜色"}}}
            """)
    }

    struct Arguments: Decodable {
        var count: Int?
        var kinds: [Kind]?
        var days: Int?
        var color: ColorName?
    }

    public func run(_ arguments: String, desk: Set<Int64>) async throws -> ToolOutput {
        guard let a = try? JSONDecoder().decode(Arguments.self, from: Data((arguments.isEmpty ? "{}" : arguments).utf8)) else { throw BadArguments() }
        var q = Query(text: "")
        q.kinds = Set(a.kinds ?? [])
        q.days = a.days
        q.colors = a.color.map { [$0] } ?? []
        let count = min(max(a.count ?? 1, 1), Self.limit)
        // Cards already on the desk aren't drawn: the model already has their original text
        let pool = Ranking.eligible(await searcher.snapshot(), q, now: .now).filter { Ranking.colorOK($0, q) && !desk.contains($0.id) }
        let picked = Array(pool.shuffled().prefix(count))
        let text = picked.isEmpty ? "没有符合条件的卡。"
            : "随机抽到 \(picked.count) 张。用户还没引用它们，不能当出处；提到时写卡名：\n" + picked.map { "c\($0.id) \($0.brief)" }.joined(separator: "\n")
        return ToolOutput(text: text, detail: String(localized: "\(picked.count) 张卡"), shown: picked.isEmpty ? nil : .cards(picked.map(\.id)))
    }
}
