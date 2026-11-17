import Foundation
import GRDB

// Records of discussing cards with AI: three tables, discussion, discussion log, and desk.
// The log is append-only, never edited or deleted; last activity, archived, and new answers are all computed from it, with no separate state

/// A discussion. With a nil name it's called "New Discussion": the model names it after the first answer
public struct Discussion: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String?
    public var createdAt: Date
    /// Sequence number of the last log entry you've seen
    public var seen: Int

    public static let databaseTableName = "discussion"

    /// The name shown in the sidebar and title row
    public var displayName: String { name ?? String(localized: "新讨论") }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One entry in the discussion log
public struct DiscussionEvent: Sendable, Equatable, Identifiable {
    public var discussion: Int64
    /// Counted from 1, consecutive within a discussion
    public var seq: Int
    public var at: Date
    public var what: Happening

    public var id: Int { seq }
}

/// What happens in a discussion. Adding a kind later is just one more case, no table change
public enum Happening: Sendable, Equatable {
    case question(String)
    case answer(Answer)
    /// The model wants to call tools, possibly several in one round; said is what it says alongside, thought is what it thinks, neither shown, both handed back to it as-is next round
    case calls(said: String, thought: String? = nil, [ToolCall])
    case result(ToolResult)
    case placed(CardMention)
    case removed(CardMention)
    case renamed(String)
}

/// An answer: the text carries citations that passed checking (written like [c12·p3]), and the citations are saved separately along with the quoted words
public struct Answer: Codable, Sendable, Equatable {
    public var text: String
    public var citations: [Citation]
    /// What the model thought before writing this answer: not shown, handed back to it as-is when the chat continues
    public var thought: String?

    public init(text: String, citations: [Citation], thought: String? = nil) {
        (self.text, self.citations, self.thought) = (text, citations, thought)
    }
}

/// A citation: points to a passage of a card, a whole card, or an item a tool call read back. The quoted words are saved, so it still shows that sentence after the card's body changes
public struct Citation: Codable, Sendable, Equatable {
    /// How it's written in the answer, without brackets: c12·p3, c12, r5·2
    public var ref: String
    public var card: Int64?
    /// Passage; nil for a whole card
    public var part: Passage.Part?
    public var number: Int?
    /// Which item read back by which tool call (counted from 1 within a discussion)
    public var call: Int?
    public var item: Int?
    /// The passage text, the whole card's title, or the item the tool read back
    public var quote: String
    /// Start second of a transcript passage: clicking plays from here
    public var seconds: Int?

    public init(ref: String, card: Int64? = nil, part: Passage.Part? = nil, number: Int? = nil, call: Int? = nil, item: Int? = nil,
                quote: String, seconds: Int? = nil) {
        (self.ref, self.card, self.part, self.number, self.call, self.item, self.quote, self.seconds) = (ref, card, part, number, call, item, quote, seconds)
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    /// The ID the model gives this call; results are matched by it
    public var id: String
    public var name: String
    /// Arguments the model filled in (JSON)
    public var arguments: String
    /// What the provider attaches to this call (JSON), not interpreted, sent back as-is next round
    public var extra: String?

    public init(id: String, name: String, arguments: String, extra: String? = nil) {
        (self.id, self.name, self.arguments, self.extra) = (id, name, arguments, extra)
    }
}

public struct ToolResult: Codable, Sendable, Equatable {
    /// Which call it answers (ToolCall.id)
    public var call: String
    /// That gray line in the conversation: "Find cards: context management", "Find cards failed"
    public var label: String
    /// Text for the model to read
    public var text: String
    /// Items that can be cited ([r5·2] means item 2)
    public var items: [String]
    /// How it's shown to you
    public var shown: Shown?
    public var failed: Bool
    /// Extra money spent (USD), counted into this discussion's cost
    public var cost: Double

    /// The few looks the discussion panel can draw; new tools pick from these instead of adding their own
    public enum Shown: Codable, Sendable, Equatable {
        /// Candidate cards, each with "put on desk"
        case cards([Int64])
    }

    public init(call: String, label: String, text: String, items: [String] = [], shown: Shown? = nil, failed: Bool = false, cost: Double = 0) {
        (self.call, self.label, self.text, self.items, self.shown, self.failed, self.cost) = (call, label, text, items, shown, failed, cost)
    }
}

/// The card put on or taken off the desk. The card name is saved with it, so the gray line can still be written after the card is permanently deleted
public struct CardMention: Codable, Sendable, Equatable {
    public var card: Int64
    public var title: String

    public init(card: Int64, title: String) { (self.card, self.title) = (card, title) }
}

/// What a sidebar row needs: the discussion, last activity, whether there's an answer you haven't seen
public struct DiscussionSummary: Sendable, Equatable, Identifiable {
    public var discussion: Discussion
    public var lastActivity: Date
    public var unread: Bool

    public var id: Int64 { discussion.id! }

    /// After 3 days without activity it goes into "Archived": it falls in naturally when the time comes, no timer needed to change it
    public func isArchived(now: Date = .now) -> Bool { lastActivity < now.addingTimeInterval(-Self.archiveAfter) }

    public static let archiveAfter: TimeInterval = 3 * 86_400
}

extension Happening {
    /// The kind name stored in the kind column
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
    // MARK: Writing

    /// The discussion is only created when the first message is sent: cards on the draft desk and the opening entries (a question, or the Q&A brought by "Continue in Discussion") in the same write
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

    /// Append to the discussion log, returning the entries written
    @discardableResult
    public func append(_ what: [Happening], to discussion: Int64) async throws -> [DiscussionEvent] {
        try await db.write { db in try Self.append(db, what, to: discussion) }
    }

    /// Put on desk: skip ones already on it, return the newly placed ones. Placed after the conversation started, the log also records a "put on desk" entry
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

    /// Take off desk: desk and log in the same write
    public func takeOffDesk(_ card: Int64, of discussion: Int64) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM discussionCard WHERE discussionID = ? AND cardID = ?", arguments: [discussion, card])
            guard db.changesCount > 0 else { return }
            if try Self.hasEvents(db, discussion) { try Self.append(db, [.removed(try Self.mention(db, card))], to: discussion) }
        }
    }

    /// Rename: the name and a "renamed" entry in the same write
    public func renameDiscussion(_ discussion: Int64, to name: String) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE discussion SET name = ? WHERE id = ?", arguments: [name, discussion])
            try Self.append(db, [.renamed(name)], to: discussion)
        }
    }

    /// Seen this discussion's log up to seq
    public func markSeen(_ discussion: Int64, through seq: Int) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE discussion SET seen = max(seen, ?) WHERE id = ?", arguments: [seq, discussion])
        }
    }

    public func deleteDiscussion(_ discussion: Int64) async throws {
        try await db.write { db in _ = try Discussion.deleteOne(db, key: discussion) }
    }

    // MARK: Reading

    public func discussion(_ id: Int64) async throws -> Discussion? {
        try await db.read { db in try Discussion.fetchOne(db, key: id) }
    }

    /// The discussion log, in order
    public func events(of discussion: Int64) async throws -> [DiscussionEvent] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM discussionEvent WHERE discussionID = ? ORDER BY seq", arguments: [discussion]).map {
                DiscussionEvent(discussion: $0["discussionID"], seq: $0["seq"], at: $0["at"], what: try Happening(kind: $0["kind"], content: $0["content"]))
            }
        }
    }

    /// Cards on the desk, in the order they were placed. Trashed ones are included: shown semi-transparent on the desk, back once restored
    public func desk(of discussion: Int64) async throws -> [Card] {
        try await db.read { db in
            try Card.fetchAll(db, sql: """
                SELECT card.* FROM discussionCard d JOIN card ON card.id = d.cardID
                WHERE d.discussionID = ? ORDER BY d.placedAt, d.rowid
                """, arguments: [discussion])
        }
    }

    /// The latest few collected cards (listed when @ is typed in a discussion before any other text)
    public func recentCards(limit: Int) async throws -> [Card] {
        try await db.read { db in
            try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE extraction = ? ORDER BY collectedAt DESC LIMIT ?", arguments: [Extraction.complete, limit])
        }
    }

    /// All discussions, most recently active first
    public func discussions() async throws -> [DiscussionSummary] {
        try await summaries("")
    }

    /// Discussions with any of these cards on the desk, most recently active first
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

    // MARK: Used inside a single write

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

    /// Put on the desk table; returns false if already on the desk
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
