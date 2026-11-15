import Foundation
import CoreGraphics
import GRDB

/// 画布读一个画板时拿到的一条：摆法 + 画这张卡要用到的内容
public struct BoardItem: Sendable, Identifiable, Equatable {
    public var id: Int64 { placement.id! }
    public var placement: Placement
    public var face: Face
    /// 聚拢时临时放大的倍数（不存进资料库）：文字类卡片的字号跟着放大，看起来和整张卡拿到眼前一样
    public var zoom: Double = 1

    public init(placement: Placement, face: Face) {
        self.placement = placement
        self.face = face
    }
}

public enum Face: Sendable, Equatable {
    case card(CardFace)
    case entry(board: Int64, name: String, collage: String?)
}

/// 画一张卡要用到的内容。正文只取开头一段，几千张卡一起读也不搬整篇文章
public struct CardFace: Sendable, Equatable, FetchableRecord, Decodable {
    /// 文字类卡片拉大后露出更多字。拉到默认的两倍宽（约 480×800）时，除去封面和要点大约放得下 1000 字；再大就该打开放大查看了
    public static let excerptLength = 1000

    public var id: Int64
    public var kind: Kind
    public var form: Form?
    public var cover: String?
    /// 原文件（动图悬停时播放它）
    public var original: String?
    public var title: String
    /// 你亲手写的文字或抽取出的正文，开头一段
    public var excerpt: String
    /// excerpt 是你亲手写的文字（引文、随手记），不是抽取的正文
    public var isOwnText: Bool
    /// 长文的要点，一行一条
    public var summary: String?
    /// 全文多少字
    public var length: Int
    public var source: String?
    public var format: String?
    public var url: String?
    public var pages: Int?
    public var duration: Double?
    /// 一共几张图（封面加其余图片）
    public var images: Int
    public var extraction: Extraction
    public var partial: Partial?
    public var understanding: Understanding?
    /// 你写的文字卡的底色名
    public var tint: String?
    /// 收进来的时间：资料库按天分组用
    public var collectedAt: Date
    /// 颜色统计（理解时从像素算的，JSON）：资料库按颜色分组用
    public var colors: String?

    /// 网址的网站名，去掉 www.
    public var site: String? {
        guard let host = url.flatMap(URL.init(string:))?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// 读卡片外观的查询列，c 是 liveCard 或 card 的别名
    static let columns = """
        c.id, c.kind, c.form, c.cover, c.original, c.extraction, c.partial, c.understanding, c.source, c.format, c.pages, c.duration, c.tint, c.collectedAt, c.colors,
        COALESCE(c.url, c.sourceURL) AS url,
        -- 显示标题的规则和 Card.displayTitle 一致，改一处要一起改
        CASE WHEN c.kind IN ('image', 'text') THEN COALESCE(c.generatedTitle, c.title, '') ELSE COALESCE(c.title, c.generatedTitle, '') END AS title,
        -- 去掉配图标记，和 Article.plain 一致
        replace(replace(substr(COALESCE(c.text, c.body, c.caption, ''), 1, \(excerptLength)), char(65532) || char(10), ''), char(65532), '') AS excerpt,
        c.summary,
        c.text IS NOT NULL AS isOwnText,
        length(COALESCE(c.text, c.body, '')) AS length,
        (c.cover IS NOT NULL) + (SELECT COUNT(*) FROM cardImage i WHERE i.cardID = c.id) AS images
        """
}

extension Store {
    // MARK: 画板

    /// 按最近打开排序
    public func boards() async throws -> [Board] {
        try await db.read { db in try Board.order(Column("openedAt").desc).fetchAll(db) }
    }

    public func createBoard(_ name: String) async throws -> Board {
        try await db.write { db in
            var board = Board(name: name)
            try board.insert(db)
            return board
        }
    }

    public func renameBoard(_ id: Int64, to name: String) async throws {
        try await db.write { db in _ = try Board.filter(key: id).updateAll(db, Column("name").set(to: name)) }
    }

    /// 换上新的缩略拼贴；旧的那张没有别处用就删掉
    public func setCollage(_ id: Int64, jpeg: Data) async throws {
        let name = try files.put(jpeg, ext: "jpg")
        for tier in FileStore.tiers { files.makeThumbnail(of: name, tier: tier, long: false) }
        let old = try await db.write { db -> String? in
            let old = try String.fetchOne(db, sql: "SELECT collage FROM board WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE board SET collage = ? WHERE id = ?", arguments: [name, id])
            return old == name || old == nil ? nil : try Self.isReferenced(db, old!) ? nil : old
        }
        if let old { files.remove(old) }
    }

    public func markOpened(_ id: Int64) async throws {
        try await db.write { db in _ = try Board.filter(key: id).updateAll(db, Column("openedAt").set(to: Date.now)) }
    }

    /// 画板里有几张卡不在任何别的画板里（删除画板前提示用）
    public func cardsOnlyOn(_ board: Int64) async throws -> [Int64] {
        try await db.read { db in try Self.cardsOnlyOn(db, board) }
    }

    static func cardsOnlyOn(_ db: Database, _ board: Int64) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT DISTINCT p.cardID FROM placement p JOIN liveCard c ON c.id = p.cardID
            WHERE p.boardID = ?1
              AND NOT EXISTS (SELECT 1 FROM placement q WHERE q.cardID = p.cardID AND q.boardID != ?1)
            """, arguments: [board])
    }

    /// 删除画板是真删。只在这里的卡按选择保留或进废纸篓；别的画板里指向它的入口随之移除
    public func deleteBoard(_ id: Int64, trashingOrphans: Bool) async throws {
        try await db.write { db in
            if trashingOrphans { try Self.setTrashed(db, try Self.cardsOnlyOn(db, id), at: .now) }
            _ = try Board.deleteOne(db, key: id)
        }
    }

    // MARK: 摆放

    /// 把一张卡放进画板，叠在最上面
    @discardableResult
    public func place(card: Int64, on board: Int64, frame: CGRect) async throws -> Placement {
        try await db.write { db in try Self.place(db, card: card, on: board, frame: frame) }
    }

    /// 一批摆放一次写进画板，叠在最上面，彼此的先后不变。新放进标记不跟着卡跑到别的画板。返回写进去的样子
    @discardableResult
    public func place(_ placements: [Placement]) async throws -> [Placement] {
        try await db.write { db in
            var top = [Int64: Double]()
            return try placements.map { p in
                var p = p
                let z = try top[p.boardID] ?? Self.topZ(db, p.boardID)
                p.id = nil
                p.unseen = false
                p.z = z + 1
                top[p.boardID] = z + 1
                try p.insert(db)
                return p
            }
        }
    }

    static func place(_ db: Database, card: Int64, on board: Int64, frame: CGRect) throws -> Placement {
        var p = Placement(boardID: board, cardID: card, frame: frame, z: try topZ(db, board) + 1)
        try p.insert(db)
        return p
    }

    /// 把画板 child 的入口放进画板 parent。嵌套不能成环
    @discardableResult
    public func placeEntry(_ child: Int64, on parent: Int64, frame: CGRect) async throws -> Placement {
        try await db.write { db in
            guard try !Self.reaches(db, from: child, to: parent) else { throw Failure.cycle }
            var p = Placement(boardID: parent, entryBoardID: child, frame: frame, z: try Self.topZ(db, parent) + 1)
            try p.insert(db)
            return p
        }
    }

    /// 沿着画板 from 里的入口一层层往下查，查得到画板 to（包括 from 就是 to）
    static func reaches(_ db: Database, from: Int64, to: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            WITH RECURSIVE reach(id) AS (
                SELECT ?1
                UNION SELECT p.entryBoardID FROM placement p JOIN reach ON p.boardID = reach.id WHERE p.entryBoardID IS NOT NULL
            )
            SELECT EXISTS(SELECT 1 FROM reach WHERE id = ?2)
            """, arguments: [from, to]) ?? false
    }

    /// 改摆放的位置、大小、角度、镜像、叠放顺序、裁剪（拖动、整理、缩放、旋转、裁剪）：只写这几行，在同一次写入里完成。
    /// 新放进标记不写：画布手里的可能是旧的。写的时候摆放已经被别处拿走（比如撤销了分拣）就跳过
    public func update(_ placements: [Placement]) async throws {
        try await db.write { db in
            for p in placements {
                do { try p.update(db, columns: ["x", "y", "width", "height", "rotation", "flipX", "flipY", "z", "crop"]) } catch RecordError.recordNotFound {}
            }
        }
    }

    /// 从这个画板拿走：只删摆放，卡片还在资料库里。返回删掉的摆放，撤销时原样放回
    @discardableResult
    public func removePlacements(_ ids: [Int64]) async throws -> [Placement] {
        try await db.write { db in
            let removed = try Placement.fetchAll(db, keys: ids)
            _ = try Placement.deleteAll(db, keys: ids)
            return removed
        }
    }

    /// 撤销、重做摆放的增删：拿走 removing，按原编号原样放回 adding。
    /// 编号不会被新摆放占用（自增不复用），撤销记录里更早的几步还认得它们。
    /// 放不回去的跳过：画板已经删了（别的画板的撤销记录还指着它），或者放回入口会绕成圈（拿走之后又反过来放了入口）
    public func exchangePlacements(adding: [Placement], removing: [Int64]) async throws {
        try await db.write { db in
            _ = try Placement.deleteAll(db, keys: removing)
            for var p in adding {
                let boards = [p.boardID] + [p.entryBoardID].compactMap { $0 }
                guard try Board.filter(keys: boards).fetchCount(db) == boards.count else { continue }
                if let child = p.entryBoardID, try Self.reaches(db, from: child, to: p.boardID) { continue }
                try p.insert(db)
            }
        }
    }

    /// 「未归类」的条件，c 是卡片表的别名
    static let unplaced = "NOT EXISTS (SELECT 1 FROM placement q WHERE q.cardID = c.id)"

    static func topZ(_ db: Database, _ board: Int64) throws -> Double {
        try Double.fetchOne(db, sql: "SELECT MAX(z) FROM placement WHERE boardID = ?", arguments: [board]) ?? 0
    }

    // MARK: 画布读取

    /// 不属于某个画板的几种卡片视图
    public enum Collection: Sendable, Hashable {
        case all, unplaced, trash
    }

    /// 视图里的卡和它在画板上用过的尺寸（没摆过的为 nil，由画布按内容定）。从新到旧：按收集时间，又收过一次的按那一次的时间
    public func cards(in collection: Collection) async throws -> [(face: CardFace, size: CGSize?)] {
        // 废纸篓以外都从未删除卡片表读
        let source = switch collection {
        case .all: "liveCard c"
        case .unplaced: "liveCard c WHERE \(Self.unplaced)"
        case .trash: "card c WHERE c.trashedAt IS NOT NULL"
        }
        return try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(CardFace.columns),
                       (SELECT width FROM placement q WHERE q.cardID = c.id LIMIT 1) AS placedWidth,
                       (SELECT height FROM placement q WHERE q.cardID = c.id LIMIT 1) AS placedHeight
                FROM \(source) ORDER BY COALESCE(c.resurfacedAt, c.collectedAt) DESC
                """)
            return try rows.map { row in
                let size = (row["placedWidth"] as Double?).map { CGSize(width: $0, height: row["placedHeight"] as Double? ?? $0) }
                return (try CardFace(row: row), size)
            }
        }
    }

    /// 一个画板里的全部摆放，按叠放顺序；废纸篓里的卡不出现
    public func items(on board: Int64) async throws -> [BoardItem] {
        try await db.read { db in
            let placements = try Placement.filter(Column("boardID") == board).order(Column("z")).fetchAll(db)
            let faces = try CardFace.fetchAll(db, sql: """
                SELECT DISTINCT \(CardFace.columns) FROM liveCard c JOIN placement p ON p.cardID = c.id WHERE p.boardID = ?
                """, arguments: [board])
            let byCard = Dictionary(faces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let entries = try Board.filter(keys: placements.compactMap(\.entryBoardID)).fetchAll(db)
            let byBoard = Dictionary(uniqueKeysWithValues: entries.map { ($0.id!, $0) })
            return placements.compactMap { p in
                if let id = p.cardID, let face = byCard[id] { return BoardItem(placement: p, face: .card(face)) }
                if let id = p.entryBoardID, let b = byBoard[id] { return BoardItem(placement: p, face: .entry(board: id, name: b.name, collage: b.collage)) }
                return nil
            }
        }
    }
}
