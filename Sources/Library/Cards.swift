import Foundation
import CoreGraphics
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// The result of collecting one thing
public enum Collected: Equatable, Sendable {
    case created(card: Int64)
    /// Already collected: restored means it was in the trash, placed means it was put on the target board this time
    case existing(card: Int64, restored: Bool, placed: Bool)
}

extension Store {
    // MARK: Collecting
    // The collect coordinator calls these in order: check URL duplicates → place a placeholder card → extract → fill in content (checking duplicates by content fingerprint) → set the final size

    /// Collect one already-extracted thing onto a board: check duplicates by URL, then by content fingerprint; if collected before, reuse that card, placing another copy even if the board already has it
    public func collect(_ m: Material, into board: Int64, frame: CGRect) async throws -> Collected {
        if let url = m.url, let existing = try await card(forURL: url) { return try await reuse(existing, on: board, frame: frame) }
        let id = try await placeholder(m.kind, url: m.url, sourceURL: m.sourceURL, title: m.title, on: board, frame: frame)
        switch try await fill(id, with: m) {
        case .filled: return .created(card: id)
        case .duplicate(let existing, let placed):
            guard case .existing(let id, let restored, let placedNow) = try await reuse(existing, on: placed ? nil : board, frame: frame) else { throw CancellationError() }
            return .existing(card: id, restored: restored, placed: placed || placedNow)
        case .gone: throw CancellationError()
        }
    }

    /// URL duplicate check: only cards "collected from exactly this URL", and cards whose collected URL redirected to this URL (a short link and the long link are the same card). Trashed ones count too
    public func card(forURL url: String) async throws -> Card? {
        guard let key = URLKey.of(url) else { return nil }
        return try await db.read { db in try Self.card(db, forKey: key) }
    }

    /// The card collected from exactly this URL comes first, then ones that redirected to it
    private static func card(_ db: Database, forKey key: String, except id: Int64? = nil) throws -> Card? {
        try Card.fetchOne(db, sql: "SELECT * FROM card WHERE (urlKey = ?1 OR finalKey = ?1) AND id != ?2 ORDER BY urlKey = ?1 DESC LIMIT 1",
                          arguments: [key, id ?? -1])
    }

    /// Placeholder card: content not extracted yet, it holds a spot on the board first (with board nil it only goes into the library)
    public func placeholder(_ kind: Kind, url: String? = nil, sourceURL: String? = nil, note: String? = nil, title: String? = nil,
                            on board: Int64?, frame: CGRect) async throws -> Int64 {
        try await db.write { db in
            var card = Card(kind: kind)
            card.url = url
            card.urlKey = url.flatMap(URLKey.of)
            card.sourceURL = sourceURL
            card.note = note
            card.title = title
            try card.insert(db)
            if let board { _ = try Self.place(db, card: card.id!, on: board, frame: frame) }
            return card.id!
        }
    }

    public enum Filled: Sendable, Equatable {
        case filled
        /// The same content was already collected: the placeholder card has been deleted, this is the existing one; placed means the placeholder's placement was handed to it
        case duplicate(of: Card, placed: Bool)
        /// The card was deleted during extraction
        case gone
    }

    /// Fill extraction results into a card (a placeholder, or a partial card being refetched): check duplicates by content fingerprint, then by the final redirected address, save files, write content. Old files swapped out are deleted if unused
    public func fill(_ id: Int64, with m: Material) async throws -> Filled {
        // Temporary files the extractor downloaded for this run are deleted once in the file store; your own files are left alone
        defer { if let original = m.original, original.path.hasPrefix(FileExtractor.downloads.path) { try? FileManager.default.removeItem(at: original) } }
        // Refetch didn't get everything: keep existing content, only update the reason
        if m.partial != nil, let card = try await card(id), card.hasContent {
            try await db.write { db in try db.execute(sql: "UPDATE card SET partial = ?, extraction = ? WHERE id = ?",
                                                      arguments: [try Self.json(m.partial), Extraction.complete, id]) }
            return .filled
        }
        let fingerprint = try m.fingerprint
        // Only trust the final address when fully fetched: otherwise it's often a login or error page address, and different content would collide
        let finalKey = m.partial == nil ? m.url.flatMap(URLKey.of) : nil
        let stored = try store(m)
        enum Outcome { case gone, duplicate(Card, placed: Bool, orphans: [String]), filled(replaced: [String]) }
        let outcome = try await db.write { db -> Outcome in
            guard var card = try Card.fetchOne(db, key: id) else { return .gone }
            // Duplicate check and write in the same write: collecting two copies of the same thing at once still leaves one card. This card's placements go to the existing one
            // The collected URL redirected elsewhere (a short link): if the final address was collected, it's the same thing. Landing somewhere broader like a home page doesn't count (URLKey.lands)
            let landed = finalKey.flatMap { $0 != card.urlKey && URLKey.lands($0, from: card.urlKey) ? $0 : nil }
            if let existing = try fingerprint.flatMap({ try Card.filter(Column("fingerprint") == $0 && Column("id") != id).fetchOne(db) })
                ?? landed.flatMap({ try Self.card(db, forKey: $0, except: id) }) {
                // The existing one is in the trash: once restored it returns to its old boards, so this card's placements on those boards are dropped
                if existing.trashedAt != nil {
                    try db.execute(sql: "DELETE FROM placement WHERE cardID = ?2 AND boardID IN (SELECT boardID FROM placement WHERE cardID = ?1)", arguments: [existing.id, id])
                }
                try db.execute(sql: "UPDATE placement SET cardID = ? WHERE cardID = ?", arguments: [existing.id, id])
                let placed = db.changesCount > 0
                let mine = try [card.cover, card.original].compactMap { $0 } + CardImage.filter(Column("cardID") == id).fetchAll(db).map(\.file)
                _ = try Card.deleteOne(db, key: id)
                let candidates = mine + [stored.cover, stored.original].compactMap { $0 } + stored.gallery
                return .duplicate(existing, placed: placed, orphans: try candidates.filter { try !Self.isReferenced(db, $0) })
            }
            let old = try [card.cover, card.original].compactMap { $0 } + CardImage.filter(Column("cardID") == id).fetchAll(db).map(\.file)
            card.kind = m.kind
            card.form = m.form
            // Keep the URL you collected (the redirected address doesn't overwrite it), so collecting the same link again finds it
            card.url = card.url ?? m.url
            card.urlKey = card.url.flatMap(URLKey.of)
            if m.partial == nil { card.finalKey = landed }
            // The collected URL redirected elsewhere: record the final page as the source
            card.sourceURL = m.sourceURL ?? (m.url != card.url ? m.url : nil) ?? card.sourceURL
            card.fingerprint = fingerprint
            card.title = m.title ?? card.title
            card.source = m.source
            card.format = m.format
            card.text = m.text
            card.body = m.body
            card.transcript = nil
            // Content changed, so the body needs completing again from the new content
            card.bodyCompleted = false
            // Cover changed, so recompute colors; content changed, so the last understanding failure is void, and a mismatched basis automatically re-queues
            if card.cover != stored.cover { card.colors = nil }
            card.understandError = nil
            card.cover = stored.cover
            card.original = stored.original
            card.player = m.player
            card.pages = m.pages
            card.duration = m.duration
            card.extraction = .complete
            card.partial = m.partial
            // Got no content: the title, description and vectors understood from the failure page can't stay, or it would look and search as if it had been fetched
            if card.isEmpty {
                (card.generatedTitle, card.caption, card.detail, card.tags, card.summary, card.summaryAnchors, card.understoodBasis) = (nil, nil, nil, [], nil, nil, nil)
                try Vector.filter(Column("cardID") == id).deleteAll(db)
            }
            try card.update(db)
            try CardImage.filter(Column("cardID") == id).deleteAll(db)
            for (i, file) in stored.gallery.enumerated() { try CardImage(cardID: id, position: i, file: file).insert(db) }
            return .filled(replaced: try old.filter { try !Self.isReferenced(db, $0) })
        }
        switch outcome {
        case .gone:
            for name in [stored.cover, stored.original].compactMap({ $0 }) + stored.gallery where !(try await isReferenced(name)) { files.remove(name) }
            return .gone
        case .duplicate(let existing, let placed, let orphans):
            for name in orphans { files.remove(name) }
            return .duplicate(of: existing, placed: placed)
        case .filled(let replaced):
            for name in replaced { files.remove(name) }
            if let cover = stored.cover { backfillThumbnails(cover, long: m.form == .long) }
            return .filled
        }
    }

    /// Mark as "Fetching" before refetching
    public func markExtracting(_ id: Int64) async throws {
        try await db.write { db in try db.execute(sql: "UPDATE card SET extraction = ? WHERE id = ?", arguments: [Extraction.extracting, id]) }
    }

    /// Partial cards (excluding trashed ones)
    public func partialCards() async throws -> [Card] {
        try await db.read { db in try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE partial IS NOT NULL") }
    }

    /// Cards still extracting at last quit. Placeholders with no content at all: those with a URL become partial cards, refetched automatically when opened;
    /// those without a URL are dropped, the original is still in the inbox and gets collected again. Old cards halfway through a refetch are kept and return to extraction-complete
    public func recoverUnfinished() async throws {
        try await db.write { db in
            let empty = "extraction = ? AND cover IS NULL AND body IS NULL AND text IS NULL AND original IS NULL"
            try db.execute(sql: "DELETE FROM card WHERE \(empty) AND url IS NULL", arguments: [Extraction.extracting])
            try db.execute(sql: "UPDATE card SET partial = ? WHERE \(empty)", arguments: [try Self.json(Partial.unfinished), Extraction.extracting])
            try db.execute(sql: "UPDATE card SET extraction = ? WHERE extraction = ?", arguments: [Extraction.complete, Extraction.extracting])
        }
    }

    private static func json(_ partial: Partial?) throws -> String { String(decoding: try JSONEncoder().encode(partial), as: UTF8.self) }

    /// Block pages kept as normal cards in the past ("Sina Visitor System"): check them once, mark the recognized ones partial, refetched automatically when opened.
    /// Content untouched: a successful refetch replaces it entirely, a failure keeps the old. Match by address; or by title, with no cover and hardly any body text (a normal article title can also contain 「安全验证」, "security check").
    /// Done only once: later collections are recognized during extraction
    public func demoteChallengePagesOnce() async throws {
        let done = "challengePagesDemoted"
        guard try await setting(done, as: Bool.self) != true else { return }
        try await db.write { db in
            for card in try Card.filter(Column("url") != nil && Column("partial") == nil).fetchAll(db) {
                let byAddress = [card.url, card.sourceURL].compactMap { $0 }.contains { WebExtractor.isChallenge(url: $0, title: nil, words: 0) }
                let byTitle = card.cover == nil && WebExtractor.isChallenge(url: "", title: card.title, words: (card.body ?? "").count)
                guard byAddress || byTitle else { continue }
                try db.execute(sql: "UPDATE card SET partial = ? WHERE id = ?", arguments: [try Self.json(Partial.unfinished), card.id!])
            }
        }
        try await setSetting(done, true)
    }

    /// Text recognized in images while completing the body is appended to the body, searchable and readable like the rest of it
    public func appendRecognizedText(_ id: Int64, _ text: String) async throws {
        guard !text.isEmpty else { return }
        try await db.write { db in
            guard var card = try Card.fetchOne(db, key: id) else { return }
            card.body = [card.body, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            try card.update(db)
        }
    }

    /// Record the transcript (local transcription or platform subtitles). Don't replace an existing one: if one card gets completed twice at once (refetched halfway through), keep only one
    public func setTranscript(_ id: Int64, _ text: String) async throws {
        guard !text.isEmpty else { return }
        try await db.write { db in
            try db.execute(sql: "UPDATE card SET transcript = ? WHERE id = ? AND transcript IS NULL", arguments: [text, id])
        }
    }

    /// An existing card collected again: bring it to the front (collection time stays, that's the first collection), record a revisit; restore it if trashed; place it on the target board, another copy even if already there.
    /// Except when it was just restored from the trash and was already on this board: restoring already put it back in place
    /// note is the line that came with the URL this time: recorded only if the card has none yet, an existing one is left alone
    public func reuse(_ card: Card, on board: Int64?, frame: CGRect, note: String? = nil) async throws -> Collected {
        try await db.write { db in
            let now = Date.now
            try db.execute(sql: "UPDATE card SET resurfacedAt = ?, note = COALESCE(note, ?) WHERE id = ?", arguments: [now, note, card.id!])
            try Self.record(db, .recollected, [card.id!], at: now)
            let restored = card.trashedAt != nil
            if restored { try Self.setTrashed(db, [card.id!], at: nil) }
            guard let board else { return .existing(card: card.id!, restored: restored, placed: false) }
            let returned = try restored && !Placement.filter(Column("boardID") == board && Column("cardID") == card.id!).isEmpty(db)
            if !returned { _ = try Self.place(db, card: card.id!, on: board, frame: frame) }
            return .existing(card: card.id!, restored: restored, placed: !returned)
        }
    }

    private func isReferenced(_ file: String) async throws -> Bool {
        try await db.read { db in try Self.isReferenced(db, file) }
    }

    private struct Stored { var cover: String?, original: String?, gallery: [String] = [] }

    /// Write images and the original file into the file store; generate the smallest thumbnail tier for the cover first so it shows right after collecting
    private func store(_ m: Material) throws -> Stored {
        var out = Stored()
        if let original = m.original { out.original = try files.put(contentsOf: original) }
        if let first = m.images.first {
            out.cover = try files.put(first, ext: Self.imageExtension(first))
            files.makeThumbnail(of: out.cover!, tier: FileStore.tiers[0], long: m.form == .long)
        }
        out.gallery = try m.images.dropFirst().map { try files.put($0, ext: Self.imageExtension($0)) }
        return out
    }

    /// The two larger thumbnail tiers are filled in in the background, so collecting dozens at once doesn't wait for them
    func backfillThumbnails(_ cover: String, long: Bool) {
        let files = self.files
        Task.detached(priority: .utility) {
            for tier in FileStore.tiers.dropFirst() { files.makeThumbnail(of: cover, tier: tier, long: long) }
        }
    }

    /// Fill in all missing thumbnail tiers for covers: ones unfinished at last quit, and imports that only made the smallest tier
    public func completeThumbnails() async throws {
        let covers = try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT DISTINCT cover, form FROM card WHERE cover IS NOT NULL").map { ($0[0] as String, $0[1] as String?) }
        }
        let files = self.files
        await Task.detached(priority: .utility) {
            for (cover, form) in covers {
                for tier in FileStore.tiers { files.makeThumbnail(of: cover, tier: tier, long: form == Form.long.rawValue) }
            }
        }.value
    }

    static func imageExtension(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let ext = UTType(type)?.preferredFilenameExtension else { return "img" }
        return ext
    }

    // MARK: Reading

    /// Those of these cards not in the trash
    public func live(_ cards: [Int64]) async throws -> Set<Int64> {
        try await db.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT id FROM liveCard WHERE id IN (\(cards.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(cards)))
        }
    }

    public func card(_ id: Int64) async throws -> Card? {
        try await db.read { db in try Card.fetchOne(db, key: id) }
    }

    /// The other images of a multi-image card, in order
    public func images(of card: Int64) async throws -> [String] {
        try await db.read { db in try CardImage.filter(Column("cardID") == card).order(Column("position")).fetchAll(db).map(\.file) }
    }

    /// Which boards this card appears on
    public func boards(containing card: Int64) async throws -> [Board] {
        try await db.read { db in
            try Board.fetchAll(db, sql: "SELECT DISTINCT board.* FROM board JOIN placement ON placement.boardID = board.id WHERE placement.cardID = ? ORDER BY board.openedAt DESC", arguments: [card])
        }
    }

    // MARK: Trash

    /// Trashing only writes a time; placements are kept, so restoring puts it back on each board as it was
    public func trash(_ cards: [Int64]) async throws {
        try await db.write { db in try Self.setTrashed(db, cards, at: .now) }
    }

    public func restore(_ cards: [Int64]) async throws {
        try await db.write { db in try Self.setTrashed(db, cards, at: nil) }
    }

    static func setTrashed(_ db: Database, _ cards: [Int64], at date: Date?) throws {
        try Card.filter(keys: cards).updateAll(db, Column("trashedAt").set(to: date))
    }

    /// Empty the trash: delete cards (placements, images, vectors go with them), then delete files no card references anymore
    public func emptyTrash() async throws {
        try await purge(nil)
    }

    /// Delete permanently: these cards in the trash (nil means all), same as emptying the trash. Ones not in the trash aren't deleted
    public func purge(_ cards: [Int64]?) async throws {
        let orphans = try await db.write { db -> [String] in
            let trashed = Card.filter(Column("trashedAt") != nil)
            let doomed = try (cards.map { trashed.filter(keys: $0) } ?? trashed).fetchAll(db)
            guard !doomed.isEmpty else { return [] }
            let candidates = try Set(doomed.flatMap { [$0.cover, $0.original].compactMap { $0 } }
                + CardImage.filter(doomed.map(\.id!).contains(Column("cardID"))).fetchAll(db).map(\.file))
            try Card.filter(keys: doomed.map(\.id!)).deleteAll(db)
            return try candidates.filter { try !Self.isReferenced(db, $0) }
        }
        for name in orphans { files.remove(name) }
    }

    static func isReferenced(_ db: Database, _ file: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM card WHERE cover = ?1 OR original = ?1)
                OR EXISTS(SELECT 1 FROM cardImage WHERE file = ?1)
                OR EXISTS(SELECT 1 FROM board WHERE collage = ?1)
            """, arguments: [file]) ?? false
    }
}
