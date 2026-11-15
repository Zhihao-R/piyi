import Foundation
import GRDB

/// 收进来以后，你又在哪儿碰到了这张卡。只存不用，留给以后的回看洞察分清「收了就没再看」和「又翻出来用了」
/// 。分拣、撤销替你做的摆放不算：那不是你的注意力
public enum Revisit: String, Sendable, DatabaseValueConvertible {
    /// 放大查看
    case opened
    /// 出现在你要的结果里：搜索、提问、抽一张、灵感
    case found, asked, drawn, inspired
    /// 你把已有的卡放进画板：移到、留下聚拢来的、又收一次时放进来的
    case placed
    /// 已经收过的又收了一次
    case recollected
    /// 打开原链接，或用别的 App 打开原文件
    case followed
    /// 放上讨论的桌
    case discussed
}

extension Store {
    /// 记下这些卡被碰到了一次；placed 带上放进的画板
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
