import CoreGraphics
import Library
import Tokens

/// 新卡落在哪由画布决定：收集、移到别的画板、放画板入口都从这里取位置
public enum Layout {
    /// 画板入口的尺寸
    public static let entrySize = CGSize(width: 240, height: 180)

    /// 一批卡按收进来的顺序排成等高的整齐几行，左上角从 origin 开始；压到别的卡就整批往下挪到空处
    public static func arranged(_ sizes: [CGSize], from origin: CGPoint, avoiding others: [CGRect]) -> [CGRect] {
        let rects = Grid.arrange(aspects: sizes.map { $0.height / $0.width }, origin: CGPoint(x: Grid.snap(origin.x), y: Grid.snap(origin.y)))
        return clear(rects, of: others)
    }

    /// 一批卡保持各自的尺寸，从左往右排成一行，放在已有卡片的下方（移到另一个画板时用）
    public static func below(_ others: [CGRect], sizes: [CGSize]) -> [CGRect] {
        let bounds = others.reduce(CGRect.null) { $0.union($1) }
        var x = bounds.isNull ? 0 : Grid.snap(bounds.minX)
        let y = bounds.isNull ? 0 : Grid.snap(bounds.maxY + Grid.unit * 2)
        return sizes.map { size in
            defer { x = Grid.snap(x + size.width + Grid.unit) }
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }

    /// 一组卡保持彼此的位置，整组的中心对准 point；压到别的卡就整批往下挪到空处（粘贴时用）
    public static func around(_ point: CGPoint, frames: [CGRect], avoiding others: [CGRect]) -> [CGRect] {
        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return frames }
        let dx = Grid.snap(point.x - bounds.width / 2) - bounds.minX, dy = Grid.snap(point.y - bounds.height / 2) - bounds.minY
        return clear(frames.map { $0.offsetBy(dx: dx, dy: dy) }, of: others)
    }

    /// 一张卡接在已有卡片的最后：最下面那一行右边还有地方就接在右边，行满了另起一行。
    /// 自动分拣找不到相似的卡时用它，一张张放进来排成几行，不摞成一竖条
    public static func appended(_ size: CGSize, to others: [CGRect]) -> CGRect {
        let bounds = others.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return CGRect(origin: .zero, size: size) }
        // 最下面那一行：和最靠下的卡在竖直方向有重叠的那些
        let lowest = others.max { $0.maxY < $1.maxY }!, row = others.filter { $0.maxY > lowest.minY }
        let x = Grid.snap(row.map(\.maxX).max()! + Grid.unit), top = row.map(\.minY).min()!
        let limit = bounds.minX + max(bounds.width, Grid.rowWidth([size.height / size.width]) * 3)
        if x + size.width <= limit { return CGRect(origin: CGPoint(x: x, y: Grid.snap(top)), size: size) }
        return below(others, sizes: [size])[0]
    }

    /// 一张卡放在 point 附近，压到别的卡就往下挪到空处
    public static func spot(_ size: CGSize, near point: CGPoint, avoiding others: [CGRect]) -> CGRect {
        clear([CGRect(x: Grid.snap(point.x - size.width / 2), y: Grid.snap(point.y - size.height / 2), width: size.width, height: size.height)], of: others)[0]
    }

    /// 聚拢：一组卡按顺序排成等高的整齐几行，尽量大、又放得进 area（屏幕点）；放不下时缩到最小行高，往下延伸。
    /// 整块在 area 里居中。张数少时不撑满宽度，免得一两张卡被拉成巨幅
    static func gathered(aspects: [CGFloat], in area: CGRect) -> [CGRect] {
        guard !aspects.isEmpty, area.width > 0, area.height > 0 else { return [] }
        // 两边留出呼吸的空间：铺满到窗边会显得挤
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

    /// 资料库（不分组时是一整组）：各组依次往下排，每组上方空出写标题的地方；所有组同一行宽，组里排成等高的整齐几行。
    /// 像一页长文那样往下读：行宽有上限，卡再多也不会排成一大块、缩到看不清。
    /// groups 是每组各张卡的高 / 宽，limit 是行宽上限；返回每组标题区的左上角和组里各张卡的矩形
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

    /// 分组标题占的高度、组与组之间多空的距离（世界坐标）
    static let shelfTitle = Grid.unit * 3, shelfGap = Grid.unit * 2
    /// 资料库的行宽上限（世界坐标）：约十张卡，常用窗口按宽取景时缩放在一半上下，标题和卡都看得清
    static let shelfWidth = Grid.unit * 120

    /// 聚拢时最小的行高（屏幕点）：再小就看不清了，宁可往下延伸
    static let gatheredMinRow: CGFloat = 96

    private static func clear(_ rects: [CGRect], of others: [CGRect]) -> [CGRect] {
        let bounds = rects.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return rects }
        let dy = Grid.clearance(for: bounds, avoiding: others)
        return rects.map { $0.offsetBy(dx: 0, dy: dy) }
    }
}

extension CanvasView {
    /// 当前画板上已有的卡占的地方
    public var occupied: [CGRect] { items.values.map(\.bounds) }

    /// 当前视野的中央（世界坐标）：粘贴的东西放这里
    public var visibleCenter: CGPoint { worldPoint(CGPoint(x: viewport.midX, y: viewport.midY)) }
}
