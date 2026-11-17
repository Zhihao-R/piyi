import Foundation
import CoreGraphics
import Library
import Intelligence
import Canvas

/// Placement for sorting: where a card goes when put into another board, near the most similar card in that board.
/// Not merged into Collector: sorting often happens long after collection finishes
struct SortPlacer: Placer {
    let store: Store

    func placements(for card: Int64, into boards: [Sorter.Scored]) async throws -> [Placement] {
        var placements: [Placement] = []
        if !boards.isEmpty, let size = try await size(of: card) {
            for target in boards {
                let items = try await store.items(on: target.board), others = items.map(\.placement.frame)
                let near = items.first { $0.placement.cardID == target.near }?.placement.frame
                // No card to be near (a board with only a rule written): append after the last row, cards added one by one forming rows
                let frame = near.map { Layout.spot(size, near: CGPoint(x: $0.midX, y: $0.midY), avoiding: others) } ?? Layout.appended(size, to: others)
                placements.append(Placement(boardID: target.board, frame: frame, z: 0))
            }
        }
        return placements
    }

    /// If the card is already placed in another board, reuse that width and height; if not placed yet, compute from content, with the cover aspect ratio read from the thumbnail's file header
    private func size(of card: Int64) async throws -> CGSize? {
        if let home = try await store.homes(of: [card], excluding: nil)[card] { return home.placement.frame.size }
        guard let c = try await store.card(card) else { return nil }
        let aspect = c.cover.flatMap { CardSize.coverAspect($0, files: store.files) }
        return CardSize.initial(kind: c.kind, coverAspect: aspect, text: c.text, hasBody: !(c.body ?? "").isEmpty)
    }
}
