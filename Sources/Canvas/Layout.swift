import CoreGraphics
import Library
import Tokens

/// Where new cards land is decided by the canvas: collecting, moving to another board, and placing board entries all get their position here
public enum Layout {
    /// Size of a board entry
    public static let entrySize = CGSize(width: 240, height: 180)

    /// Arrange a batch of cards in collection order into neat rows of equal height, top-left corner at origin; if it covers other cards, move the whole batch down to free space
    public static func arranged(_ sizes: [CGSize], from origin: CGPoint, avoiding others: [CGRect]) -> [CGRect] {
        let rects = Grid.arrange(aspects: sizes.map { $0.height / $0.width }, origin: CGPoint(x: Grid.snap(origin.x), y: Grid.snap(origin.y)))
        return clear(rects, of: others)
    }

    /// A batch of cards keeping their own sizes, laid left to right in one row below the existing cards (used when moving to another board)
    public static func below(_ others: [CGRect], sizes: [CGSize]) -> [CGRect] {
        let bounds = others.reduce(CGRect.null) { $0.union($1) }
        var x = bounds.isNull ? 0 : Grid.snap(bounds.minX)
        let y = bounds.isNull ? 0 : Grid.snap(bounds.maxY + Grid.unit * 2)
        return sizes.map { size in
            defer { x = Grid.snap(x + size.width + Grid.unit) }
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }

    /// A group of cards keeping their relative positions, with the group's center on point; if it covers other cards, move the whole batch down to free space (used when pasting)
    public static func around(_ point: CGPoint, frames: [CGRect], avoiding others: [CGRect]) -> [CGRect] {
        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return frames }
        let dx = Grid.snap(point.x - bounds.width / 2) - bounds.minX, dy = Grid.snap(point.y - bounds.height / 2) - bounds.minY
        return clear(frames.map { $0.offsetBy(dx: dx, dy: dy) }, of: others)
    }

    /// One card appended after the existing cards: to the right of the bottom row if there's room, otherwise on a new row.
    /// Used when auto sorting finds no similar card, so cards placed one at a time form rows instead of piling into a vertical strip
    public static func appended(_ size: CGSize, to others: [CGRect]) -> CGRect {
        let bounds = others.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return CGRect(origin: .zero, size: size) }
        // The bottom row: cards that overlap vertically with the lowest card
        let lowest = others.max { $0.maxY < $1.maxY }!, row = others.filter { $0.maxY > lowest.minY }
        let x = Grid.snap(row.map(\.maxX).max()! + Grid.unit), top = row.map(\.minY).min()!
        let limit = bounds.minX + max(bounds.width, Grid.rowWidth([size.height / size.width]) * 3)
        if x + size.width <= limit { return CGRect(origin: CGPoint(x: x, y: Grid.snap(top)), size: size) }
        return below(others, sizes: [size])[0]
    }

    /// One card placed near point; if it covers other cards, move it down to free space
    public static func spot(_ size: CGSize, near point: CGPoint, avoiding others: [CGRect]) -> CGRect {
        clear([CGRect(x: Grid.snap(point.x - size.width / 2), y: Grid.snap(point.y - size.height / 2), width: size.width, height: size.height)], of: others)[0]
    }

    /// Gathering: arrange a set of cards in order into neat rows of equal height, as large as possible while fitting in area (screen points); when they don't fit, shrink to the minimum row height and extend downward.
    /// The whole block is centered in area. With few cards it doesn't fill the width, so one or two cards don't get blown up huge
    static func gathered(aspects: [CGFloat], in area: CGRect) -> [CGRect] {
        guard !aspects.isEmpty, area.width > 0, area.height > 0 else { return [] }
        // Leave breathing room on both sides: filling all the way to the window edge feels cramped
        let area = area.insetBy(dx: area.width * 0.06, dy: 0)
        let tallest = min(area.height * (aspects.count == 1 ? 0.75 : 0.45), 360)
        var rowHeight = max(tallest, gatheredMinRow)
        var rects: [CGRect] = []
        while true {
            rects = Grid.justify(aspects: aspects, width: area.width, rowHeight: rowHeight, origin: .zero)
            let height = rects.map(\.maxY).max()!
            if height <= area.height || rowHeight <= gatheredMinRow { break }
            rowHeight = max(gatheredMinRow, rowHeight * 0.92)
        }
        let block = rects.reduce(CGRect.null) { $0.union($1) }
        let dx = area.minX + (area.width - block.width) / 2, dy = area.minY + max(0, (area.height - block.height) / 2)
        return rects.map { $0.offsetBy(dx: dx, dy: dy) }
    }

    /// Library (one whole group when ungrouped): groups go one after another downward, each with room above for its title; all groups share one row width, and each group is laid out in neat rows of equal height.
    /// Read downward like a long page: the row width is capped, so however many cards there are they never form one big block shrunk too small to see.
    /// groups are each card's height / width per group, limit is the row-width cap; returns each group's title-area top-left corner and the rects of the cards in it
    static func shelves(_ groups: [[CGFloat]], width limit: CGFloat = shelfWidth) -> [(title: CGPoint, rects: [CGRect])] {
        let all = groups.flatMap { $0 }, rowHeight = CGFloat(Space.rowHeight)
        let width = max(min(Grid.rowWidth(all), limit), all.map { rowHeight / $0 }.max() ?? 0)
        var y: CGFloat = 0
        return groups.map { aspects in
            let rects = Grid.justify(aspects: aspects, width: width, rowHeight: rowHeight, origin: CGPoint(x: 0, y: y + shelfTitle))
            defer { y = (rects.map(\.maxY).max() ?? y + shelfTitle) + shelfGap }
            return (CGPoint(x: 0, y: y), rects)
        }
    }

    /// Height taken by a group title, and the extra space between groups (world coordinates)
    static let shelfTitle = Grid.unit * 3, shelfGap = Grid.unit * 2
    /// Row-width cap for the library (world coordinates): about ten cards; at common window sizes fitted to width the zoom is around half, so titles and cards are both readable
    static let shelfWidth = Grid.unit * 120

    /// Minimum row height when gathering (screen points): any smaller is unreadable, so extend downward instead
    static let gatheredMinRow: CGFloat = 96

    private static func clear(_ rects: [CGRect], of others: [CGRect]) -> [CGRect] {
        let bounds = rects.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return rects }
        let dy = Grid.clearance(for: bounds, avoiding: others)
        return rects.map { $0.offsetBy(dx: 0, dy: dy) }
    }
}

extension CanvasView {
    /// The area taken by cards already on the current board
    public var occupied: [CGRect] { items.values.map(\.bounds) }

    /// Center of the current view (world coordinates): pasted things go here
    public var visibleCenter: CGPoint { worldPoint(CGPoint(x: viewport.midX, y: viewport.midY)) }
}
