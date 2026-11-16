import Foundation
import GRDB

// 和 AI 讨论卡片的讨论记录：讨论、讨论记录、桌三张表。
// 讨论记录只往后追加，不改不删；最近一次动静、已归档、新回答都从它现算，不另存状态

/// 一段讨论。名字为 nil 时叫「新讨论」：第一个回答出来后由模型起名
public struct Discussion: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String?
    public var createdAt: Date
    /// 你看过的最后一条记录的序号
    public var seen: Int

    public static let databaseTableName = "discussion"

    /// 侧边栏、标题行显示的名字
    public var displayName: String { name ?? String(localized: "新讨论") }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 讨论记录里的一条
public struct DiscussionEvent: Sendable, Equatable, Identifiable {
    public var discussion: Int64
    /// 从 1 数，一段讨论里连续
    public var seq: Int
    public var at: Date
    public var what: Happening

    public var id: Int { seq }
}

/// 讨论里发生的事。以后要加一种，只是多一个 case，不用改表
public enum Happening: Sendable, Equatable {
    case question(String)
    case answer(Answer)
    /// 模型要调用工具，一轮里可能同时要几个；said 是它同时说的话、thought 是它想的，都不显示，下一轮原样交回给它
    case calls(said: String, thought: String? = nil, [ToolCall])
    case result(ToolResult)
    case placed(CardMention)
    case removed(CardMention)
    case renamed(String)
}

/// 回答：文字里带着通过检查的引用（[c12·p3] 这种写法），引用连同原话另存一份
public struct Answer: Codable, Sendable, Equatable {
    public var text: String
    public var citations: [Citation]
    /// 模型写这段回答前想的内容：不显示，接着聊时原样交回给它
    public var thought: String?

    public init(text: String, citations: [Citation], thought: String? = nil) {
        (self.text, self.citations, self.thought) = (text, citations, thought)
    }
}

/// 一个引用：指向某张卡的某一段、整张卡，或某次工具读回的某一项。原话存下来，卡的正文以后变了也照样显示当时那句
public struct Citation: Codable, Sendable, Equatable {
    /// 回答里的写法，不带方括号：c12·p3、c12、r5·2
    public var ref: String
    public var card: Int64?
    /// 段落；整张卡时为 nil
    public var part: Passage.Part?
    public var number: Int?
    /// 第几次工具调用（一段讨论里从 1 数）读回的第几项
    public var call: Int?
    public var item: Int?
    /// 段落原文、整张卡的标题、工具读回的那一项
    public var quote: String
    /// 转录段的开始秒数：点了从这里播
    public var seconds: Int?

    public init(ref: String, card: Int64? = nil, part: Passage.Part? = nil, number: Int? = nil, call: Int? = nil, item: Int? = nil,
                quote: String, seconds: Int? = nil) {
        (self.ref, self.card, self.part, self.number, self.call, self.item, self.quote, self.seconds) = (ref, card, part, number, call, item, quote, seconds)
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    /// 模型给这次调用起的编号，结果按它配对
    public var id: String
    public var name: String
    /// 模型填的参数（JSON）
    public var arguments: String
    /// 服务商附在这次调用上的东西（JSON），不解读，下一轮原样带回
    public var extra: String?

    public init(id: String, name: String, arguments: String, extra: String? = nil) {
        (self.id, self.name, self.arguments, self.extra) = (id, name, arguments, extra)
    }
}

public struct ToolResult: Codable, Sendable, Equatable {
    /// 对应哪次调用（ToolCall.id）
    public var call: String
    /// 对话里那行灰字：「找卡：上下文管理」「找卡没成功」
    public var label: String
    /// 交给模型看的文字
    public var text: String
    /// 能被引用的几项（[r5·2] 指第 2 项）
    public var items: [String]
    /// 给你看的样子
    public var shown: Shown?
    public var failed: Bool
    /// 另外花的钱（美元），计入这段讨论的花费
    public var cost: Double

    /// 讨论栏里能画的几种样子，新工具从里面挑，不另起
    public enum Shown: Codable, Sendable, Equatable {
        /// 候选卡，每张带「放上桌」
        case cards([Int64])
    }

    public init(call: String, label: String, text: String, items: [String] = [], shown: Shown? = nil, failed: Bool = false, cost: Double = 0) {
        (self.call, self.label, self.text, self.items, self.shown, self.failed, self.cost) = (call, label, text, items, shown, failed, cost)
    }
}

/// 放上桌、拿下桌的那张卡。卡名一起存：卡彻底删了，灰字照样写得出来
public struct CardMention: Codable, Sendable, Equatable {
    public var card: Int64
    public var title: String

    public init(card: Int64, title: String) { (self.card, self.title) = (card, title) }
}

/// 侧边栏一行要的：讨论、最近一次动静、有没有你还没看过的回答
public struct DiscussionSummary: Sendable, Equatable, Identifiable {
    public var discussion: Discussion
    public var lastActivity: Date
    public var unread: Bool

    public var id: Int64 { discussion.id! }

    /// 3 天没有动静就收进「已归档」：到时间自然算进去，不用定时去改
    public func isArchived(now: Date = .now) -> Bool { lastActivity < now.addingTimeInterval(-Self.archiveAfter) }

    public static let archiveAfter: TimeInterval = 3 * 86_400
}

extension Happening {
    /// 存进 kind 列的种类名
    var kind: String {
        switch self {
        case .question: "question"
        case .answer: "answer"
        case .calls: "calls"
        case .result: "result"
        case .placed: "placed"
        case .removed: "removed"
        case .renamed: "renamed"
        }
    }

    private struct Said: Codable { var text: String }
    private struct Calls: Codable { var said: String; var thought: String?; var calls: [ToolCall] }

    func content() throws -> String {
        let data = switch self {
        case .question(let text), .renamed(let text): try JSONEncoder().encode(Said(text: text))
        case .answer(let answer): try JSONEncoder().encode(answer)
        case .calls(let said, let thought, let calls): try JSONEncoder().encode(Calls(said: said, thought: thought, calls: calls))
        case .result(let result): try JSONEncoder().encode(result)
        case .placed(let mention), .removed(let mention): try JSONEncoder().encode(mention)
        }
        return String(decoding: data, as: UTF8.self)
    }

    init(kind: String, content: String) throws {
        let data = Data(content.utf8), decoder = JSONDecoder()
        switch kind {
        case "question": self = .question(try decoder.decode(Said.self, from: data).text)
        case "renamed": self = .renamed(try decoder.decode(Said.self, from: data).text)
        case "answer": self = .answer(try decoder.decode(Answer.self, from: data))
        case "calls":
            let calls = try decoder.decode(Calls.self, from: data)
            self = .calls(said: calls.said, thought: calls.thought, calls.calls)
        case "result": self = .result(try decoder.decode(ToolResult.self, from: data))
        case "placed": self = .placed(try decoder.decode(CardMention.self, from: data))
        case "removed": self = .removed(try decoder.decode(CardMention.self, from: data))
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "讨论记录的种类不认识：\(kind)"))
        }
    }
}

extension Store {
    // MARK: 写

    /// 发出第一句话时才建讨论：草稿桌上的卡和开头几条记录（问题，或「接着聊」带来的问答）同一次写入
    public func startDiscussion(desk cards: [Int64], opening: [Happening]) async throws -> Int64 {
        try await db.write { db in
            var discussion = Discussion(name: nil, createdAt: .now, seen: 0)
            try discussion.insert(db)
            let id = discussion.id!
            for card in cards { try Self.putOnDesk(db, card, id) }
            try Self.append(db, opening, to: id)
            return id
        }
    }

    /// 往讨论记录后面追加，返回写下的几条
    @discardableResult
    public func append(_ what: [Happening], to discussion: Int64) async throws -> [DiscussionEvent] {
        try await db.write { db in try Self.append(db, what, to: discussion) }
    }

    /// 放上桌：桌上已经有的跳过，返回新放上的。对话开始后放上的，讨论记录里同时记一条「放上桌」
    public func placeOnDesk(_ cards: [Int64], of discussion: Int64) async throws -> [Int64] {
        try await db.write { db in
            let started = try Self.hasEvents(db, discussion)
            var placed: [Int64] = []
            for card in cards where try Self.putOnDesk(db, card, discussion) {
                placed.append(card)
                if started { try Self.append(db, [.placed(try Self.mention(db, card))], to: discussion) }
            }
            return placed
        }
    }

    /// 拿下桌：桌和讨论记录同一次写入
    public func takeOffDesk(_ card: Int64, of discussion: Int64) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM discussionCard WHERE discussionID = ? AND cardID = ?", arguments: [discussion, card])
            guard db.changesCount > 0 else { return }
            if try Self.hasEvents(db, discussion) { try Self.append(db, [.removed(try Self.mention(db, card))], to: discussion) }
        }
    }

    /// 改名：名字和一条「改名」记录同一次写入
    public func renameDiscussion(_ discussion: Int64, to name: String) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE discussion SET name = ? WHERE id = ?", arguments: [name, discussion])
            try Self.append(db, [.renamed(name)], to: discussion)
        }
    }

    /// 看过了这段讨论到 seq 为止的记录
    public func markSeen(_ discussion: Int64, through seq: Int) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE discussion SET seen = max(seen, ?) WHERE id = ?", arguments: [seq, discussion])
        }
    }

    public func deleteDiscussion(_ discussion: Int64) async throws {
        try await db.write { db in _ = try Discussion.deleteOne(db, key: discussion) }
    }

    // MARK: 读

    public func discussion(_ id: Int64) async throws -> Discussion? {
        try await db.read { db in try Discussion.fetchOne(db, key: id) }
    }

    /// 讨论记录，按顺序
    public func events(of discussion: Int64) async throws -> [DiscussionEvent] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM discussionEvent WHERE discussionID = ? ORDER BY seq", arguments: [discussion]).map {
                DiscussionEvent(discussion: $0["discussionID"], seq: $0["seq"], at: $0["at"], what: try Happening(kind: $0["kind"], content: $0["content"]))
            }
        }
    }

    /// 桌上的卡，按放上来的先后。进了废纸篓的也在：桌上显示成半透明，恢复了就回来
    public func desk(of discussion: Int64) async throws -> [Card] {
        try await db.read { db in
            try Card.fetchAll(db, sql: """
                SELECT card.* FROM discussionCard d JOIN card ON card.id = d.cardID
                WHERE d.discussionID = ? ORDER BY d.placedAt, d.rowid
                """, arguments: [discussion])
        }
    }

    /// 最近收的几张（讨论里 @ 还没打字时列出来）
    public func recentCards(limit: Int) async throws -> [Card] {
        try await db.read { db in
            try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE extraction = ? ORDER BY collectedAt DESC LIMIT ?", arguments: [Extraction.complete, limit])
        }
    }

    /// 全部讨论，最近有动静的在前
    public func discussions() async throws -> [DiscussionSummary] {
        try await summaries("")
    }

    /// 桌上有这几张卡之一的讨论，最近有动静的在前
    public func discussions(about cards: [Int64]) async throws -> [DiscussionSummary] {
        guard !cards.isEmpty else { return [] }
        return try await summaries("WHERE d.id IN (SELECT discussionID FROM discussionCard WHERE cardID IN (\(cards.map(String.init).joined(separator: ","))))")
    }

    private func summaries(_ filter: String) async throws -> [DiscussionSummary] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.*,
                    (SELECT max(at) FROM discussionEvent e WHERE e.discussionID = d.id) AS lastActivity,
                    (SELECT max(seq) FROM discussionEvent e WHERE e.discussionID = d.id AND e.kind = 'answer') AS lastAnswer
                FROM discussion d \(filter) ORDER BY lastActivity DESC
                """).map { row in
                let discussion = try Discussion(row: row)
                let lastAnswer: Int? = row["lastAnswer"]
                return DiscussionSummary(discussion: discussion, lastActivity: row["lastActivity"] ?? discussion.createdAt,
                                         unread: (lastAnswer ?? 0) > discussion.seen)
            }
        }
    }

    // MARK: 同一次写入里用的

    @discardableResult
    static func append(_ db: Database, _ what: [Happening], to discussion: Int64) throws -> [DiscussionEvent] {
        var seq = try Int.fetchOne(db, sql: "SELECT max(seq) FROM discussionEvent WHERE discussionID = ?", arguments: [discussion]) ?? 0
        let now = Date.now
        return try what.map { happening in
            seq += 1
            try db.execute(sql: "INSERT INTO discussionEvent (discussionID, seq, kind, content, at) VALUES (?, ?, ?, ?, ?)",
                           arguments: [discussion, seq, happening.kind, try happening.content(), now])
            return DiscussionEvent(discussion: discussion, seq: seq, at: now, what: happening)
        }
    }

    /// 放上桌这张表；已经在桌上返回 false
    @discardableResult
    private static func putOnDesk(_ db: Database, _ card: Int64, _ discussion: Int64) throws -> Bool {
        try db.execute(sql: "INSERT OR IGNORE INTO discussionCard (discussionID, cardID, placedAt) VALUES (?, ?, ?)",
                       arguments: [discussion, card, Date.now])
        return db.changesCount > 0
    }

    private static func hasEvents(_ db: Database, _ discussion: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM discussionEvent WHERE discussionID = ?)", arguments: [discussion]) ?? false
    }

    private static func mention(_ db: Database, _ card: Int64) throws -> CardMention {
        CardMention(card: card, title: try Card.fetchOne(db, key: card)?.displayTitle ?? "")
    }
}
