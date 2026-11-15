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
            // 画布、搜索、向量、灵感、计数都从这里读，不靠每处查询自己记得排除废纸篓
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
            // 理解排到哪一步，画布和状态栏读它
            try db.alter(table: "card") { t in t.add(column: "understanding", .text) }
            // 早期版本导入的卡已经有云端生成的标题和描述：记上依据，只重算向量，不重新生成。
            // 只读用到的几列：Card 跟着后面的版本加了列，这时表里还没有
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
            // 之前只有本地的视频、音频会转录，它们抽取时没有正文：有正文的就是转过的
            try db.execute(sql: "UPDATE card SET transcribed = 1 WHERE kind IN ('video', 'audio') AND original IS NOT NULL AND body IS NOT NULL AND body != ''")
        }
        migrator.registerMigration("v5") { db in
            // 自动分拣：已有的画板全部打开，规则为空
            try db.alter(table: "board") { t in
                t.add(column: "autoSort", .boolean).notNull().defaults(to: true)
                t.add(column: "rule", .text)
            }
        }
        migrator.registerMigration("v6") { db in
            // 已有的卡都算分拣过、补全过正文：升级后不把整个资料库重新分一遍，想分的话用「分拣这些卡」
            try db.alter(table: "card") { t in
                t.add(column: "sorted", .boolean).notNull().defaults(to: false)
                t.add(column: "bodyCompleted", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE card SET sorted = 1, bodyCompleted = 1")
            try db.alter(table: "placement") { t in t.add(column: "unseen", .boolean).notNull().defaults(to: false) }
        }
        migrator.registerMigration("v7") { db in
            try db.alter(table: "card") { t in t.add(column: "tint", .text) }
            // 以前粘贴、从手机收进来的纯文本也是你的文字：都能改
            try db.execute(sql: "UPDATE card SET form = 'note' WHERE kind = 'text' AND url IS NULL AND form IS NULL")
        }
        migrator.registerMigration("v8") { db in
            // 回看记录：画板删了记录还在，卡从废纸篓清掉才跟着删
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
            // 已经收的 YouTube、B 站视频按网址补上嵌入播放器；别的网站的要重新抓取才有。
            // 规则照当时的 Player 抄一份：升级只跑一次，不跟着以后的改动变
            for row in try Row.fetchAll(db, sql: "SELECT id, url, sourceURL FROM card WHERE kind = 'video' AND original IS NULL") {
                let urls = [row["sourceURL"], row["url"]].compactMap { ($0 as String?).flatMap(URLComponents.init(string:)) }
                guard let player = urls.lazy.compactMap(Self.v9Player).first else { continue }
                try db.execute(sql: "UPDATE card SET player = ? WHERE id = ?", arguments: [player, row["id"] as Int64])
            }
        }
        migrator.registerMigration("v10") { db in
            // 转录从正文里分出来单独存：放大查看里和简介分开排。转录总是最后补进正文的，最后一个空行之后的就是它；
            // 拼回去和原来的正文一样，理解的依据不变，不会重新排队
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
            // 和 AI 讨论。桌上的卡指向 card 不指向 liveCard：进了废纸篓的卡还留在桌上，清空废纸篓时跟着删
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
                // 又收到一次的时间：收集时间不改，默认排序按它提到最前
                t.add(column: "resurfacedAt", .datetime)
                // 和网址一起带来的那句话
                t.add(column: "note", .text)
                // 跳转后的最终地址，查重用
                t.add(column: "finalKey", .text)
            }
            try db.create(index: "card_on_finalKey", on: "card", columns: ["finalKey"])
            // 已有的卡：收的网址跳转过的，出处里记着最终地址，补成 finalKey。图片卡的出处是图所在的网页，不是最终地址，不补
            for row in try Row.fetchAll(db, sql: "SELECT id, urlKey, sourceURL FROM card WHERE url IS NOT NULL AND sourceURL IS NOT NULL AND partial IS NULL AND kind != 'image'") {
                let urlKey: String? = row["urlKey"]
                guard let key = URLKey.of(row["sourceURL"]), key != urlKey, URLKey.lands(key, from: urlKey) else { continue }
                try db.execute(sql: "UPDATE card SET finalKey = ? WHERE id = ?", arguments: [key, row["id"] as Int64])
            }
        }
        migrator.registerMigration("v13") { db in
            // 要点带上依据的段落
            try db.alter(table: "card") { t in t.add(column: "summaryAnchors", .jsonText) }
            // 理解的做法改了两处：要点以前只读开头 2500 字，标签以前被提示词里的例子带偏。已有的卡全部重新理解一遍；
            // 向量跟着新的标签自己重算，不用清
            try db.execute(sql: "UPDATE card SET understoodBasis = NULL WHERE understoodBasis IS NOT NULL")
        }
        return migrator
    }

    /// v9 补播放地址用的规则：YouTube 认 watch?v= 和 youtu.be/编号，B 站认网址里的 BV 号
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
