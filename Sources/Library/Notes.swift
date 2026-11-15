import Foundation
import CoreGraphics
import GRDB

/// 你的文字卡里你定的那部分：文字（Markdown）和底色。改它就是改这两样
public struct Note: Sendable, Equatable {
    public var card: Int64
    public var text: String
    /// 底色名（见 Palette.tints）；nil 是卡片本来的底色
    public var tint: String?

    public init(card: Int64, text: String, tint: String?) {
        (self.card, self.text, self.tint) = (card, text, tint)
    }
}

extension Store {
    /// 写一张文字卡放进画板，返回它的摆放。不查重：同样的话可以写两遍；
    /// 不自动分拣：写在哪个画板就属于哪个画板；没有要补全的正文
    public func createNote(_ text: String, on board: Int64, frame: CGRect) async throws -> Placement {
        try await db.write { db in try Self.place(db, card: try Self.insertNote(db, text), on: board, frame: frame) }
    }

    /// 写一张文字卡只进资料库，不放进画板（讨论的回答收成文字卡时，人不在画板里）
    public func createNote(_ text: String) async throws -> Int64 {
        try await db.write { db in try Self.insertNote(db, text) }
    }

    private static func insertNote(_ db: Database, _ text: String) throws -> Int64 {
        var card = Card(kind: .text)
        card.form = .note
        card.text = text
        card.extraction = .complete
        card.bodyCompleted = true
        card.sorted = true
        try card.insert(db)
        return card.id!
    }

    /// 这几张里你的文字卡（网页帖子里只有字的那种不算）
    public func notes(_ cards: [Int64]) async throws -> [Note] {
        try await db.read { db in
            try Card.filter(keys: cards).filter(Column("form") == Form.note).fetchAll(db)
                .map { Note(card: $0.id!, text: $0.text ?? "", tint: $0.tint) }
        }
    }

    /// 改文字和底色，只改你的文字卡。文字变了理解的依据跟着变，下一轮理解按新内容重做；
    /// 内容指纹作废，再粘贴一遍原来那段话就是一张新卡
    public func saveNotes(_ notes: [Note]) async throws {
        try await db.write { db in
            for note in notes {
                try db.execute(sql: """
                    UPDATE card SET fingerprint = CASE WHEN text IS ?1 THEN fingerprint END, text = ?1, tint = ?2
                    WHERE id = ?3 AND form = ?4
                    """, arguments: [note.text, note.tint, note.card, Form.note])
            }
        }
    }
}
