import Foundation
import CoreGraphics
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// 收一样东西的结果
public enum Collected: Equatable, Sendable {
    case created(card: Int64)
    /// 已经收过：restored 表示它原来在废纸篓里，placed 表示这次放进了目标画板
    case existing(card: Int64, restored: Bool, placed: Bool)
}

extension Store {
    // MARK: 收集
    // 收集协调者按这个顺序调：网址查重 → 放占位卡 → 抽取 → 填进内容（按内容指纹查重）→ 定最终尺寸

    /// 收一样已经抽取好的东西放进画板：先按网址、再按内容指纹查重；收过的就复用那张卡，画板里已经有也再放一份
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

    /// 按网址查重：只管「收的就是这个网址」的卡，和收的网址跳转到这个网址的卡（短链接、长链接是同一张）。废纸篓里的也算
    public func card(forURL url: String) async throws -> Card? {
        guard let key = URLKey.of(url) else { return nil }
        return try await db.read { db in try Self.card(db, forKey: key) }
    }

    /// 收的就是这个网址的那张优先，其次才是跳转到这个网址的
    private static func card(_ db: Database, forKey key: String, except id: Int64? = nil) throws -> Card? {
        try Card.fetchOne(db, sql: "SELECT * FROM card WHERE (urlKey = ?1 OR finalKey = ?1) AND id != ?2 ORDER BY urlKey = ?1 DESC LIMIT 1",
                          arguments: [key, id ?? -1])
    }

    /// 占位卡：内容还没抽取，先在画板上占个位置（board 为 nil 时只进资料库）
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
        /// 同样的内容已经收过：占位卡已删掉，这是已有那张；placed 表示占位卡的摆放转给了它
        case duplicate(of: Card, placed: Bool)
        /// 抽取期间卡被删了
        case gone
    }

    /// 抽取结果填进卡（占位卡，或重新抓取的残缺卡）：按内容指纹、再按跳转后的最终地址查重，存文件，写内容。换下来的旧文件没人用就删掉
    public func fill(_ id: Int64, with m: Material) async throws -> Filled {
        // 抽取器为这次下载的临时文件，存进文件库后就删掉；你自己的文件不动
        defer { if let original = m.original, original.path.hasPrefix(FileExtractor.downloads.path) { try? FileManager.default.removeItem(at: original) } }
        // 重新抓取没抓全：已有的内容留着，只更新原因
        if m.partial != nil, let card = try await card(id), card.hasContent {
            try await db.write { db in try db.execute(sql: "UPDATE card SET partial = ?, extraction = ? WHERE id = ?",
                                                      arguments: [try Self.json(m.partial), Extraction.complete, id]) }
            return .filled
        }
        let fingerprint = try m.fingerprint
        // 抓全了才认最终地址：没抓全时它常是登录页、报错页的地址，不同的内容会撞到一起
        let finalKey = m.partial == nil ? m.url.flatMap(URLKey.of) : nil
        let stored = try store(m)
        enum Outcome { case gone, duplicate(Card, placed: Bool, orphans: [String]), filled(replaced: [String]) }
        let outcome = try await db.write { db -> Outcome in
            guard var card = try Card.fetchOne(db, key: id) else { return .gone }
            // 查重和写入在同一次写入里：同时收进两份同样的东西也只留一张。这张卡的摆放交给已有那张
            // 收的网址跳转到了别处（短链接）：最终地址收过，也是同一样东西。跳到首页之类更泛的地方不算（URLKey.lands）
            let landed = finalKey.flatMap { $0 != card.urlKey && URLKey.lands($0, from: card.urlKey) ? $0 : nil }
            if let existing = try fingerprint.flatMap({ try Card.filter(Column("fingerprint") == $0 && Column("id") != id).fetchOne(db) })
                ?? landed.flatMap({ try Self.card(db, forKey: $0, except: id) }) {
                // 已有那张在废纸篓里：恢复后它回到原来的画板，那些画板上这张的摆放就不要了
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
            // 网址按你收的那个保留（跳转后的地址不覆盖它），再收同一个链接才查得到
            card.url = card.url ?? m.url
            card.urlKey = card.url.flatMap(URLKey.of)
            if m.partial == nil { card.finalKey = landed }
            // 收的网址跳转到了别处：最终页面记作出处
            card.sourceURL = m.sourceURL ?? (m.url != card.url ? m.url : nil) ?? card.sourceURL
            card.fingerprint = fingerprint
            card.title = m.title ?? card.title
            card.source = m.source
            card.format = m.format
            card.text = m.text
            card.body = m.body
            card.transcript = nil
            // 内容换了，正文要按新内容重新补全
            card.bodyCompleted = false
            // 封面换了颜色重算；内容变了，上次理解失败的原因作废，依据对不上会自动重新排队
            if card.cover != stored.cover { card.colors = nil }
            card.understandError = nil
            card.cover = stored.cover
            card.original = stored.original
            card.player = m.player
            card.pages = m.pages
            card.duration = m.duration
            card.extraction = .complete
            card.partial = m.partial
            // 没抓到内容：之前按失败页理解出的标题、描述和向量不能留，不然看着、搜着都像抓到了
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

    /// 重新抓取前标成「正在抽取」
    public func markExtracting(_ id: Int64) async throws {
        try await db.write { db in try db.execute(sql: "UPDATE card SET extraction = ? WHERE id = ?", arguments: [Extraction.extracting, id]) }
    }

    /// 残缺卡（不含废纸篓里的）
    public func partialCards() async throws -> [Card] {
        try await db.read { db in try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE partial IS NOT NULL") }
    }

    /// 上次退出时还在抽取的卡。没有任何内容的占位卡：有网址的转成残缺卡，打开后自动重新抓；
    /// 没网址的丢掉，原件还在收件箱里，会重收一遍。重新抓取到一半的老卡留着，回到抽取完成
    public func recoverUnfinished() async throws {
        try await db.write { db in
            let empty = "extraction = ? AND cover IS NULL AND body IS NULL AND text IS NULL AND original IS NULL"
            try db.execute(sql: "DELETE FROM card WHERE \(empty) AND url IS NULL", arguments: [Extraction.extracting])
            try db.execute(sql: "UPDATE card SET partial = ? WHERE \(empty)", arguments: [try Self.json(Partial.unfinished), Extraction.extracting])
            try db.execute(sql: "UPDATE card SET extraction = ? WHERE extraction = ?", arguments: [Extraction.complete, Extraction.extracting])
        }
    }

    private static func json(_ partial: Partial?) throws -> String { String(decoding: try JSONEncoder().encode(partial), as: UTF8.self) }

    /// 以前被当成正常卡留下的拦截页（「Sina Visitor System」）：认一遍，认出来的标成残缺，打开后自动重新抓。
    /// 内容不动：重抓成功会整个换掉，失败时旧的还在。认地址；或者认标题，且没有封面、正文没几个字（正常文章的标题里也可能有「安全验证」）。
    /// 只做一次：之后收的在抽取时就认出来了
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

    /// 补全正文识别出的图中文字补进正文，和其它正文一样能搜、能读
    public func appendRecognizedText(_ id: Int64, _ text: String) async throws {
        guard !text.isEmpty else { return }
        try await db.write { db in
            guard var card = try Card.fetchOne(db, key: id) else { return }
            card.body = [card.body, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            try card.update(db)
        }
    }

    /// 记下转录（本机转录或平台字幕）。已经有的不换：同一张卡同时补两次（补到一半又重新抓取）时只留一份
    public func setTranscript(_ id: Int64, _ text: String) async throws {
        guard !text.isEmpty else { return }
        try await db.write { db in
            try db.execute(sql: "UPDATE card SET transcript = ? WHERE id = ? AND transcript IS NULL", arguments: [text, id])
        }
    }

    /// 又收到已有的卡：提到最前（收集时间不动，那是第一次收的时间），记一次回看；在废纸篓里就恢复；放进目标画板，已经有也再放一份。
    /// 只有刚从废纸篓恢复、它原本就在这个画板上时不再放：恢复已经让它回到原位了
    /// note 是这次和网址一起带来的那句话：卡上还没有才记，已有的不动
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

    /// 图片、原文件写进文件库，封面先生成最小一档缩略图，收进来马上就能显示
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

    /// 大的两档缩略图在后台补，一次收进几十张时不用等它们
    func backfillThumbnails(_ cover: String, long: Bool) {
        let files = self.files
        Task.detached(priority: .utility) {
            for tier in FileStore.tiers.dropFirst() { files.makeThumbnail(of: cover, tier: tier, long: long) }
        }
    }

    /// 补齐所有封面缺的缩略图档位：上次退出时没补完的、导入时只生成了最小一档的
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

    // MARK: 读

    /// 这几张里还没进废纸篓的
    public func live(_ cards: [Int64]) async throws -> Set<Int64> {
        try await db.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT id FROM liveCard WHERE id IN (\(cards.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(cards)))
        }
    }

    public func card(_ id: Int64) async throws -> Card? {
        try await db.read { db in try Card.fetchOne(db, key: id) }
    }

    /// 多图卡的其余图片，按顺序
    public func images(of card: Int64) async throws -> [String] {
        try await db.read { db in try CardImage.filter(Column("cardID") == card).order(Column("position")).fetchAll(db).map(\.file) }
    }

    /// 这张卡出现在哪些画板里
    public func boards(containing card: Int64) async throws -> [Board] {
        try await db.read { db in
            try Board.fetchAll(db, sql: "SELECT DISTINCT board.* FROM board JOIN placement ON placement.boardID = board.id WHERE placement.cardID = ? ORDER BY board.openedAt DESC", arguments: [card])
        }
    }

    // MARK: 废纸篓

    /// 进废纸篓只写时间，摆放记录保留，恢复时原样回到各个画板
    public func trash(_ cards: [Int64]) async throws {
        try await db.write { db in try Self.setTrashed(db, cards, at: .now) }
    }

    public func restore(_ cards: [Int64]) async throws {
        try await db.write { db in try Self.setTrashed(db, cards, at: nil) }
    }

    static func setTrashed(_ db: Database, _ cards: [Int64], at date: Date?) throws {
        try Card.filter(keys: cards).updateAll(db, Column("trashedAt").set(to: date))
    }

    /// 清空废纸篓：删卡（摆放、图片、向量随之删除），再删掉已经没有任何卡引用的文件
    public func emptyTrash() async throws {
        try await purge(nil)
    }

    /// 彻底删除：废纸篓里的这几张（nil 是全部），做法同清空废纸篓。不在废纸篓里的不删
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
