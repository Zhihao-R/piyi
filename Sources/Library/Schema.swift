import Foundation
import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "card") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("form", .text)
                t.column("collectedAt", .datetime).notNull()
                t.column("url", .text)
                t.column("urlKey", .text).indexed()
                t.column("sourceURL", .text)
                t.column("fingerprint", .text).indexed()
                t.column("title", .text)
                t.column("source", .text)
                t.column("format", .text)
                t.column("text", .text)
                t.column("body", .text)
                t.column("cover", .text)
                t.column("original", .text)
                t.column("pages", .integer)
                t.column("duration", .double)
                t.column("extraction", .text).notNull()
                t.column("partial", .jsonText)
                t.column("trashedAt", .datetime)
                t.column("generatedTitle", .text)
                t.column("caption", .text)
                t.column("detail", .text)
                t.column("tags", .jsonText).notNull()
                t.column("summary", .text)
                t.column("colors", .jsonText)
                t.column("understoodBasis", .text)
                t.column("understandError", .text)
            }
            // The canvas, search, vectors, inspiration and counts all read from here, instead of relying on each query to remember to exclude the trash
            try db.execute(sql: "CREATE VIEW liveCard AS SELECT * FROM card WHERE trashedAt IS NULL")

            try db.create(table: "cardImage") { t in
                t.belongsTo("card", onDelete: .cascade).notNull()
                t.column("position", .integer).notNull()
                t.column("file", .text).notNull()
                t.primaryKey(["cardID", "position"])
            }
            try db.create(table: "vector") { t in
                t.primaryKey("cardID", .integer).references("card", onDelete: .cascade)
                t.column("model", .text).notNull()
                t.column("basis", .text).notNull()
                t.column("data", .blob).notNull()
            }
            try db.create(table: "board") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("collage", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("openedAt", .datetime).notNull()
            }
            try db.create(table: "placement") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("board", onDelete: .cascade).notNull()
                t.belongsTo("card", onDelete: .cascade)
                t.belongsTo("entryBoard", inTable: "board", onDelete: .cascade)
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("width", .double).notNull()
                t.column("height", .double).notNull()
                t.column("rotation", .double).notNull()
                t.column("crop", .jsonText)
                t.column("z", .double).notNull()
                t.check(sql: "(cardID IS NULL) != (entryBoardID IS NULL)")
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            // How far understanding is queued; the canvas and status bar read it
            try db.alter(table: "card") { t in t.add(column: "understanding", .text) }
            // Cards imported by early versions already have cloud-generated titles and descriptions: record their basis, recompute only vectors, don't regenerate.
            // Read only the columns used: Card gained columns in later versions that the table doesn't have yet
            for row in try Row.fetchAll(db, sql: "SELECT id, title, body, text, cover FROM card WHERE caption IS NOT NULL AND understoodBasis IS NULL") {
                let id: Int64 = row["id"]
                let title: String? = row["title"], body: String? = row["body"], text: String? = row["text"], cover: String? = row["cover"]
                let basis = Card.basis(title: title, body: body, text: text, cover: cover)
                try db.execute(sql: "UPDATE card SET understoodBasis = ? WHERE id = ?", arguments: [basis, id])
            }
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: "placement") { t in
                t.add(column: "flipX", .boolean).notNull().defaults(to: false)
                t.add(column: "flipY", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v4") { db in
            try db.alter(table: "card") { t in t.add(column: "transcribed", .boolean).notNull().defaults(to: false) }
            // Previously only local video and audio were transcribed, and they had no body when extracted: any with a body was transcribed
            try db.execute(sql: "UPDATE card SET transcribed = 1 WHERE kind IN ('video', 'audio') AND original IS NOT NULL AND body IS NOT NULL AND body != ''")
        }
        migrator.registerMigration("v5") { db in
            // Auto-sort: turn it on for all existing boards, with an empty rule
            try db.alter(table: "board") { t in
                t.add(column: "autoSort", .boolean).notNull().defaults(to: true)
                t.add(column: "rule", .text)
            }
        }
        migrator.registerMigration("v6") { db in
            // Treat all existing cards as sorted and body-completed: upgrading doesn't re-sort the whole library; to sort, use "Sort These Cards"
            try db.alter(table: "card") { t in
                t.add(column: "sorted", .boolean).notNull().defaults(to: false)
                t.add(column: "bodyCompleted", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE card SET sorted = 1, bodyCompleted = 1")
            try db.alter(table: "placement") { t in t.add(column: "unseen", .boolean).notNull().defaults(to: false) }
        }
        migrator.registerMigration("v7") { db in
            try db.alter(table: "card") { t in t.add(column: "tint", .text) }
            // Plain text pasted or collected from the phone before is also your text: all editable
            try db.execute(sql: "UPDATE card SET form = 'note' WHERE kind = 'text' AND url IS NULL AND form IS NULL")
        }
        migrator.registerMigration("v8") { db in
            // Revisit records: kept when a board is deleted, removed only when the card is cleared from the trash
            try db.create(table: "revisit") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.belongsTo("card", onDelete: .cascade).notNull()
                t.belongsTo("board", onDelete: .setNull)
                t.column("at", .datetime).notNull()
            }
        }
        migrator.registerMigration("v9") { db in
            try db.alter(table: "card") { t in t.add(column: "player", .text) }
            // Fill in embed players by URL for YouTube and Bilibili videos already collected; other sites need a refetch to get one.
            // The rules are copied from Player as it was then: a migration runs only once and shouldn't change with later edits
            for row in try Row.fetchAll(db, sql: "SELECT id, url, sourceURL FROM card WHERE kind = 'video' AND original IS NULL") {
                let urls = [row["sourceURL"], row["url"]].compactMap { ($0 as String?).flatMap(URLComponents.init(string:)) }
                guard let player = urls.lazy.compactMap(Self.v9Player).first else { continue }
                try db.execute(sql: "UPDATE card SET player = ? WHERE id = ?", arguments: [player, row["id"] as Int64])
            }
        }
        migrator.registerMigration("v10") { db in
            // Store transcripts separately from the body: listed apart from the description in the detail view. The transcript was always the last thing added to the body, so it's whatever follows the last blank line;
            // joined back it equals the old body, so the understanding basis doesn't change and nothing re-queues
            try db.alter(table: "card") { t in t.add(column: "transcript", .text) }
            for row in try Row.fetchAll(db, sql: "SELECT id, body FROM card WHERE transcribed = 1 AND body IS NOT NULL") {
                let body: String = row["body"]
                let split = body.range(of: "\n\n", options: .backwards)
                try db.execute(sql: "UPDATE card SET body = ?, transcript = ? WHERE id = ?",
                               arguments: [split.map { String(body[..<$0.lowerBound]) }, split.map { String(body[$0.upperBound...]) } ?? body, row["id"] as Int64])
            }
            try db.alter(table: "card") { t in t.drop(column: "transcribed") }
        }
        migrator.registerMigration("v11") { db in
            // Discussing with AI. Desk cards point to card, not liveCard: trashed cards stay on the desk and are deleted with them when the trash is emptied
            try db.create(table: "discussion") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("seen", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "discussionEvent") { t in
                t.belongsTo("discussion", onDelete: .cascade).notNull()
                t.column("seq", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("content", .jsonText).notNull()
                t.column("at", .datetime).notNull()
                t.primaryKey(["discussionID", "seq"])
            }
            try db.create(table: "discussionCard") { t in
                t.belongsTo("discussion", onDelete: .cascade).notNull()
                t.belongsTo("card", onDelete: .cascade).notNull()
                t.column("placedAt", .datetime).notNull()
                t.primaryKey(["discussionID", "cardID"])
            }
        }
        migrator.registerMigration("v12") { db in
            try db.alter(table: "card") { t in
                // When it was collected again: collection time doesn't change, the default order brings it to the front by this
                t.add(column: "resurfacedAt", .datetime)
                // The line that came with the URL
                t.add(column: "note", .text)
                // Final address after redirects, for the duplicate check
                t.add(column: "finalKey", .text)
            }
            try db.create(index: "card_on_finalKey", on: "card", columns: ["finalKey"])
            // Existing cards: for collected URLs that redirected, the source records the final address, so fill it into finalKey. An image card's source is the page the image was on, not a final address, so skip it
            for row in try Row.fetchAll(db, sql: "SELECT id, urlKey, sourceURL FROM card WHERE url IS NOT NULL AND sourceURL IS NOT NULL AND partial IS NULL AND kind != 'image'") {
                let urlKey: String? = row["urlKey"]
                guard let key = URLKey.of(row["sourceURL"]), key != urlKey, URLKey.lands(key, from: urlKey) else { continue }
                try db.execute(sql: "UPDATE card SET finalKey = ? WHERE id = ?", arguments: [key, row["id"] as Int64])
            }
        }
        migrator.registerMigration("v13") { db in
            // Key points carry the passage they're based on
            try db.alter(table: "card") { t in t.add(column: "summaryAnchors", .jsonText) }
            // Understanding changed in two ways: key points used to read only the first 2500 characters, and tags were skewed by the examples in the prompt. Re-understand all existing cards;
            // vectors recompute on their own with the new tags, no need to clear them
            try db.execute(sql: "UPDATE card SET understoodBasis = NULL WHERE understoodBasis IS NOT NULL")
        }
        return migrator
    }

    /// Rules for filling in player addresses in v9: YouTube matches watch?v= and youtu.be/<id>, Bilibili matches the BV ID in the URL
    private static func v9Player(_ url: URLComponents) -> String? {
        let host = url.host?.lowercased() ?? ""
        let query = { (name: String) in url.queryItems?.first { $0.name == name }?.value }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            return query("v").map { "https://www.youtube.com/embed/\($0)" }
        }
        if host == "youtu.be" {
            return url.path.split(separator: "/").first.map { "https://www.youtube.com/embed/\($0)" }
        }
        if host == "bilibili.com" || host.hasSuffix(".bilibili.com"), let bv = url.path.firstMatch(#"BV[0-9A-Za-z]{10}"#) {
            return "https://player.bilibili.com/player.html?bvid=\(bv)&p=\(query("p").flatMap(Int.init) ?? 1)"
        }
        return nil
    }
}
