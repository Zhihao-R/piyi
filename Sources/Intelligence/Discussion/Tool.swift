import Foundation
import Library

/// AI 在回答过程中可以调用的一项能力。讨论内核不认识具体的工具，只认这份写法：加一个工具只是多写一个
public protocol Tool: Sendable {
    /// 给模型看的：英文名、什么时候该用、参数格式
    var spec: ToolSpec { get }
    /// 给你看的名字：「找卡」
    var title: String { get }
    var nature: ToolNature { get }
    /// 拿到模型填的参数（JSON），执行。desk 是眼下桌上的卡。出错就抛，内核替它写「没成功」
    func run(_ arguments: String, desk: Set<Int64>) async throws -> ToolOutput
}

/// 只读的直接执行；改资料的先摆成提议，你点了才执行（第一版没有改资料的工具）
public enum ToolNature: Sendable { case reading, changing }

public struct ToolOutput: Sendable {
    /// 交给模型看的文字，内核截到 4000 字
    public var text: String
    /// 对话里那行灰字冒号后面的：「找卡：上下文管理」的「上下文管理」
    public var detail: String
    /// 能被引用的几项
    public var items: [String] = []
    public var shown: ToolResult.Shown?
    /// 另外花的钱（美元）
    public var cost = 0.0

    public init(text: String, detail: String, items: [String] = [], shown: ToolResult.Shown? = nil, cost: Double = 0) {
        (self.text, self.detail, self.items, self.shown, self.cost) = (text, detail, items, shown, cost)
    }
}

/// 模型填的参数不是约定的格式
struct BadArguments: LocalizedError {
    var errorDescription: String? { "参数格式不对" }
}

/// 找卡：参数直接是搜索条件，构造查询调 Searcher.find。不让搜索再理解一遍这句话：讨论里的模型已经理解过了，再理解要多等约 3 秒。
/// 找到的是候选卡：还没放上桌，只摆出来让你挑，不能当依据引用
public struct FindCards: Tool {
    let searcher: Searcher
    /// 最多交回几张
    static let limit = 8

    public init(searcher: Searcher) { self.searcher = searcher }

    public let title = "找卡"
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
        // 桌上已有的不算候选：模型手里已经有它的原文
        let found = Array(await searcher.find(q, online: true).filter { !desk.contains($0) }.prefix(Self.limit))
        // 停下了：搜索不会抛错，这里补一句，免得把半截的结果当成「没找到」
        try Task.checkCancellation()
        let briefs = Dictionary(uniqueKeysWithValues: await searcher.snapshot().map { ($0.id, $0.brief) })
        let lines = found.compactMap { id in briefs[id].map { "c\(id) \($0)" } }
        let text = lines.isEmpty ? "没找到相关的卡。"
            : "找到 \(lines.count) 张候选卡。用户还没引用它们，不能当出处；需要的话建议用户引用：\n" + lines.joined(separator: "\n")
        return ToolOutput(text: text, detail: a.text, shown: found.isEmpty ? nil : .cards(found))
    }
}

/// 随机抽卡：模型会按意思找，但不会碰运气，「抽一张帮我解读」「随便挑几张我看看」缺的就是这一样。
/// 给了它这个工具，这类话由它自己理解，不用为每种说法写一条规则。
/// 抽到的和找卡找到的一样是候选卡：摆出来让你挑，不能当依据引用
public struct PickRandomCards: Tool {
    let searcher: Searcher
    /// 一次最多抽几张
    static let limit = 5

    public init(searcher: Searcher) { self.searcher = searcher }

    public let title = "随机抽卡"
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
        // 桌上已有的不抽：模型手里已经有它的原文
        let pool = Ranking.eligible(await searcher.snapshot(), q, now: .now).filter { Ranking.colorOK($0, q) && !desk.contains($0.id) }
        let picked = Array(pool.shuffled().prefix(count))
        let text = picked.isEmpty ? "没有符合条件的卡。"
            : "随机抽到 \(picked.count) 张。用户还没引用它们，不能当出处；提到时写卡名：\n" + picked.map { "c\($0.id) \($0.brief)" }.joined(separator: "\n")
        return ToolOutput(text: text, detail: "\(picked.count) 张", shown: picked.isEmpty ? nil : .cards(picked.map(\.id)))
    }
}
