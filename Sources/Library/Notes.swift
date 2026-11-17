import Foundation
import CoreGraphics
import GRDB

/// The part of your text card you decide: the text (Markdown) and background color. Editing it means editing these two
public struct Note: Sendable, Equatable {
    public var card: Int64
    public var text: String
    /// Background color name (see Palette.tints); nil is the card's default background
    public var tint: String?

    public init(card: Int64, text: String, tint: String?) {
        (self.card, self.text, self.tint) = (card, text, tint)
    }
}

extension Store {
    /// Write a text card and put it on a board, returning its placement. No duplicate check: the same words can be written twice;
    /// no automatic sorting: it belongs to the board it was written on; there's no body to complete
    public func createNote(_ text: String, on board: Int64, frame: CGRect) async throws -> Placement {
        try await db.write { db in try Self.place(db, card: try Self.insertNote(db, text), on: board, frame: frame) }
    }

    /// Write a text card into the library only, not onto a board (when a discussion answer is saved as a text card, you're not on a board)
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

    /// Your text cards among these (text-only posts from web pages don't count)
    public func notes(_ cards: [Int64]) async throws -> [Note] {
        try await db.read { db in
            try Card.filter(keys: cards).filter(Column("form") == Form.note).fetchAll(db)
                .map { Note(card: $0.id!, text: $0.text ?? "", tint: $0.tint) }
        }
    }

    /// Edit text and background color, only on your text cards. When the text changes the understanding basis changes with it, and the next understanding round redoes it from the new content;
    /// the content fingerprint is voided, so pasting the original passage again makes a new card
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
