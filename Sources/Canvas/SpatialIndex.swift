import CoreGraphics

/// Buckets placements into 1024-square cells to quickly find the ones that intersect a region
struct SpatialIndex {
    private static let cell: CGFloat = 1024
    private var buckets: [Cell: [Int64]] = [:]
    private var frames: [Int64: CGRect] = [:]

    private struct Cell: Hashable { var x: Int, y: Int }

    init(_ frames: [Int64: CGRect]) {
        for (id, frame) in frames { insert(id, frame) }
    }

    mutating func insert(_ id: Int64, _ frame: CGRect) {
        frames[id] = frame
        for cell in Self.cells(frame) { buckets[cell, default: []].append(id) }
    }

    mutating func remove(_ id: Int64) {
        guard let frame = frames.removeValue(forKey: id) else { return }
        for cell in Self.cells(frame) { buckets[cell]?.removeAll { $0 == id } }
    }

    mutating func update(_ id: Int64, _ frame: CGRect) {
        remove(id)
        insert(id, frame)
    }

    func ids(in rect: CGRect) -> Set<Int64> {
        guard let (xs, ys) = Self.span(rect) else { return [] }
        // When zoomed far out the view covers more cells than there are cells with cards, so check the cells with cards one by one instead
        let cells = xs.count * ys.count <= buckets.count
            ? xs.flatMap { x in ys.map { Cell(x: x, y: $0) } }
            : buckets.keys.filter { xs.contains($0.x) && ys.contains($0.y) }
        var out = Set<Int64>()
        for cell in cells {
            for id in buckets[cell] ?? [] where frames[id]!.intersects(rect) { out.insert(id) }
        }
        return out
    }

    /// Bounding box of all placements
    var bounds: CGRect { frames.values.reduce(CGRect.null) { $0.union($1) } }

    private static func span(_ r: CGRect) -> (ClosedRange<Int>, ClosedRange<Int>)? {
        guard !r.isNull, r.width.isFinite, r.height.isFinite else { return nil }
        func range(_ lo: CGFloat, _ hi: CGFloat) -> ClosedRange<Int> { Int((lo / cell).rounded(.down))...Int((hi / cell).rounded(.down)) }
        return (range(r.minX, r.maxX), range(r.minY, r.maxY))
    }

    private static func cells(_ r: CGRect) -> [Cell] {
        guard let (xs, ys) = span(r) else { return [] }
        return xs.flatMap { x in ys.map { Cell(x: x, y: $0) } }
    }
}
