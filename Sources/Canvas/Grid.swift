import CoreGraphics
import Tokens

/// The canvas grid: cards are axis-aligned, one grid unit apart.
/// When dragging, edges near a neighbor snap to it (top to top, bottom to bottom, or one gap apart); with nothing nearby to align to, the top-left corner snaps to the grid on release.
enum Grid {
    /// Grid unit (world coordinates), also the standard spacing between cards. Layouts arranged directly in screen space, like search and inspiration, use the same number as screen points
    static let unit = CGFloat(Space.unit)
    /// Snap when edges are within this many screen points
    static let tolerance: CGFloat = 10
    /// Only align with neighbors within this distance on screen (about one card wide), so it doesn't line up oddly with cards on the far side of the canvas
    static let reach: CGFloat = 200

    static func snap(_ v: CGFloat) -> CGFloat { (v / unit).rounded() * unit }

    /// Snap the top-left corner to the grid, keeping the size
    static func snapped(_ rect: CGRect) -> CGRect {
        CGRect(origin: CGPoint(x: snap(rect.minX), y: snap(rect.minY)), size: rect.size)
    }

    /// Alignment guide (world coordinates): runs along the shared edge, covering only the gap between the two cards. side is which way is outside the cards: -1 left/up, 1 right/down
    struct Guide: Equatable {
        var from: CGPoint
        var to: CGPoint
        var side: CGFloat
    }

    /// Snap result: how far to move in each direction (nil means nothing nearby to align to in that direction), plus the guides to draw
    struct Alignment: Equatable {
        var dx: CGFloat?
        var dy: CGFloat?
        var guides: [Guide] = []

        var offset: CGSize { CGSize(width: dx ?? 0, height: dy ?? 0) }
    }

    /// A candidate: one of its own edges moves to target. flush means same-edge alignment (draws a guide); otherwise it sits one gap away (no guide)
    private struct Candidate {
        var edge: CGFloat
        var target: CGFloat
        var other: CGRect
        var flush: Bool
        var distance: CGFloat { abs(target - edge) }
    }

    /// Snaps rect's edges to neighbors' edges. The two directions are searched separately, each taking the smallest move. tolerance and reach are already converted to world coordinates
    static func align(_ rect: CGRect, to others: [CGRect], tolerance: CGFloat, reach: CGFloat) -> Alignment {
        var xs: [Candidate] = [], ys: [Candidate] = []
        for o in others {
            if gap(rect.minY, rect.maxY, o.minY, o.maxY) < reach {
                xs += [Candidate(edge: rect.minX, target: o.minX, other: o, flush: true),
                       Candidate(edge: rect.maxX, target: o.maxX, other: o, flush: true),
                       Candidate(edge: rect.minX, target: o.maxX + unit, other: o, flush: false),
                       Candidate(edge: rect.maxX, target: o.minX - unit, other: o, flush: false)]
            }
            if gap(rect.minX, rect.maxX, o.minX, o.maxX) < reach {
                ys += [Candidate(edge: rect.minY, target: o.minY, other: o, flush: true),
                       Candidate(edge: rect.maxY, target: o.maxY, other: o, flush: true),
                       Candidate(edge: rect.minY, target: o.maxY + unit, other: o, flush: false),
                       Candidate(edge: rect.maxY, target: o.minY - unit, other: o, flush: false)]
            }
        }
        let nearest = { (cs: [Candidate]) in cs.filter { $0.distance <= tolerance }.min { $0.distance < $1.distance } }
        let bestX = nearest(xs), bestY = nearest(ys)

        var result = Alignment(dx: bestX.map { $0.target - $0.edge }, dy: bestY.map { $0.target - $0.edge })
        let moved = rect.offsetBy(dx: result.offset.width, dy: result.offset.height)
        if let x = bestX, x.flush, let span = between(moved.minY, moved.maxY, x.other.minY, x.other.maxY) {
            result.guides.append(Guide(from: CGPoint(x: x.target, y: span.0), to: CGPoint(x: x.target, y: span.1),
                                       side: x.target == x.other.minX ? -1 : 1))
        }
        if let y = bestY, y.flush, let span = between(moved.minX, moved.maxX, y.other.minX, y.other.maxX) {
            result.guides.append(Guide(from: CGPoint(x: span.0, y: y.target), to: CGPoint(x: span.1, y: y.target),
                                       side: y.target == y.other.minY ? -1 : 1))
        }
        return result
    }

    /// The empty stretch between two intervals; nil when they touch or overlap (then there's no gap to draw a guide in)
    private static func between(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> (CGFloat, CGFloat)? {
        let lo = min(a1, b1), hi = max(a0, b0)
        return lo < hi ? (lo, hi) : nil
    }

    /// The gap between two intervals; 0 when they overlap
    private static func gap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, max(a0, b0) - min(a1, b1))
    }

    /// How far to move bounds down so it doesn't cover any other card (one grid unit apart, top edge still on the grid)
    static func clearance(for bounds: CGRect, avoiding others: [CGRect]) -> CGFloat {
        var dy: CGFloat = 0
        while let hit = others.first(where: { $0.insetBy(dx: -unit / 2, dy: -unit / 2).intersects(bounds.offsetBy(dx: 0, dy: dy)) }) {
            dy = (ceil((hit.maxY + unit) / unit) * unit) - bounds.minY
        }
        return dy
    }

    /// Arrange a set of cards into neat rows: the row width keeps the whole close to 16:10 (a common window ratio), and at least wide enough for the widest card. aspects are each card's height / width
    static func arrange(aspects: [CGFloat], origin: CGPoint) -> [CGRect] {
        guard !aspects.isEmpty else { return [] }
        return justify(aspects: aspects, width: rowWidth(aspects), rowHeight: CGFloat(Space.rowHeight), origin: origin)
    }

    /// What row width to use when arranging these cards into neat rows
    static func rowWidth(_ aspects: [CGFloat]) -> CGFloat {
        let rowHeight = CGFloat(Space.rowHeight)
        let area = aspects.reduce(0) { $0 + (rowHeight + unit) * (rowHeight / $1 + unit) }
        return snap(max(sqrt(area * 1.6), aspects.map { rowHeight / $0 }.max() ?? 0))
    }

    /// Neat layout: in order, into rows of equal height, each row exactly filling the same width (the last row isn't stretched); row and column spacing are both one grid unit.
    /// So that both left and right edges line up, row heights aren't rounded to the grid; tidied cards align with each other's edges rather than with the grid.
    /// Returns each card's rect (world coordinates), with the top-left corner starting at origin
    static func justify(aspects: [CGFloat], width: CGFloat, rowHeight: CGFloat, origin: CGPoint) -> [CGRect] {
        var rects: [CGRect] = []
        var row: [CGFloat] = []           // Width / height of each card in the current row
        var y = origin.y
        func flush(stretch: Bool) {
            let gaps = unit * CGFloat(row.count - 1)
            let h = stretch ? (width - gaps) / row.reduce(0, +) : rowHeight
            var x = origin.x
            for r in row {
                rects.append(CGRect(x: x, y: y, width: h * r, height: h))
                x += h * r + unit
            }
            y += h + unit
            row = []
        }
        for aspect in aspects {
            row.append(1 / aspect)
            if row.reduce(0, +) * rowHeight + unit * CGFloat(row.count - 1) >= width { flush(stretch: true) }
        }
        if !row.isEmpty { flush(stretch: false) }
        return rects
    }
}
