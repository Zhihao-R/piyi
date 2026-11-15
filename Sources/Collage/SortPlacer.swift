import Foundation
import CoreGraphics
import Library
import Intelligence
import Canvas

/// 分拣的落位：卡放进别的画板时摆在哪，靠近画板里和它最像的那张。
/// 不并进 Collector：分拣常在收集结束很久以后才发生
struct SortPlacer: Placer {
    let store: Store

    func placements(for card: Int64, into boards: [Sorter.Scored]) async throws -> [Placement] {
        var placements: [Placement] = []
        if !boards.isEmpty, let size = try await size(of: card) {
            for target in boards {
                let items = try await store.items(on: target.board), others = items.map(\.placement.frame)
                let near = items.first { $0.placement.cardID == target.near }?.placement.frame
                // 没有可靠近的卡（只写了规则的画板）：接在最后一行后面，一张张放进来排成几行
                let frame = near.map { Layout.spot(size, near: CGPoint(x: $0.midX, y: $0.midY), avoiding: others) } ?? Layout.appended(size, to: others)
                placements.append(Placement(boardID: target.board, frame: frame, z: 0))
            }
        }
        return placements
    }

    /// 卡已经摆在别的画板里就沿用那份的宽高；还没摆过的按内容算，封面宽高比从缩略图的文件头读
    private func size(of card: Int64) async throws -> CGSize? {
        if let home = try await store.homes(of: [card], excluding: nil)[card] { return home.placement.frame.size }
        guard let c = try await store.card(card) else { return nil }
        let aspect = c.cover.flatMap { CardSize.coverAspect($0, files: store.files) }
        return CardSize.initial(kind: c.kind, coverAspect: aspect, text: c.text, hasBody: !(c.body ?? "").isEmpty)
    }
}
