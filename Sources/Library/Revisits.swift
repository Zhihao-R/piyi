import Foundation
import GRDB

/// Where you ran into this card again after collecting it. Stored but unused for now, kept for future revisit insights to tell "collected and never looked at again" from "dug out and used again"
/// . Placements made for you by sorting or undo don't count: that's not your attention
public enum Revisit: String, Sendable, DatabaseValueConvertible {
    /// Detail view
    case opened
    /// Showed up in results you asked for: search, questions, Draw a Card, inspiration
    case found, asked, drawn, inspired
    /// You put an existing card on a board: moved there, kept from a gather, placed when collected again
    case placed
    /// Collected again after already being collected
    case recollected
    /// Opened the original link, or opened the original file in another app
    case followed
    /// Put on a discussion's desk
    case discussed
}

extension Store {
    /// Record that these cards were run into once; placed carries the board it was put on
    public func record(_ revisit: Revisit, _ cards: [Int64], board: Int64? = nil) async throws {
        guard !cards.isEmpty else { return }
        try await db.write { db in try Self.record(db, revisit, cards, board: board, at: .now) }
    }

    static func record(_ db: Database, _ revisit: Revisit, _ cards: [Int64], board: Int64? = nil, at date: Date) throws {
        for card in cards {
            try db.execute(sql: "INSERT INTO revisit (kind, cardID, boardID, at) VALUES (?, ?, ?, ?)",
                           arguments: [revisit, card, board, date])
        }
    }
}
