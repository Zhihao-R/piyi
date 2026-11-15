import CoreGraphics
import Tokens

/// 画布的网格：卡片横平竖直，彼此间隔一个网格单位。
/// 拖动时边缘靠近邻居就吸过去（顶边对顶边、底边对底边、或者隔一个间距贴着）；附近没有可对齐的，松手时左上角吸到网格。
enum Grid {
    /// 网格单位（世界坐标），也是卡片之间的标准间距。搜索、灵感这类直接按屏幕排的版面，同一个数当屏幕点用
    static let unit = CGFloat(Space.unit)
    /// 边缘相差多少屏幕点以内就吸附
    static let tolerance: CGFloat = 10
    /// 只和屏幕上这个距离以内的邻居对齐（约一张卡宽），避免和画布另一头的卡片莫名其妙地对上
    static let reach: CGFloat = 200

    static func snap(_ v: CGFloat) -> CGFloat { (v / unit).rounded() * unit }

    /// 左上角吸到网格，尺寸不变
    static func snapped(_ rect: CGRect) -> CGRect {
        CGRect(origin: CGPoint(x: snap(rect.minX), y: snap(rect.minY)), size: rect.size)
    }

    /// 对齐辅助线（世界坐标）
    struct Guide: Equatable {
        var from: CGPoint
        var to: CGPoint
    }

    /// 吸附结果：每个方向上要挪多少（nil 表示这个方向附近没有可对齐的），以及要画的辅助线
    struct Alignment: Equatable {
        var dx: CGFloat?
        var dy: CGFloat?
        var guides: [Guide] = []

        var offset: CGSize { CGSize(width: dx ?? 0, height: dy ?? 0) }
    }

    /// 一个候选：自己的某条边要挪到 target。flush 是同边对齐（画线），否则是隔一格贴着（不画线）
    private struct Candidate {
        var edge: CGFloat
        var target: CGFloat
        var other: CGRect
        var flush: Bool
        var distance: CGFloat { abs(target - edge) }
    }

    /// 把 rect 的边吸到邻居的边上。两个方向分开找，各取挪动最少的那个。tolerance、reach 都已换算成世界坐标
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
        if let x = bestX, x.flush {
            result.guides.append(Guide(from: CGPoint(x: x.target, y: min(moved.minY, x.other.minY)),
                                       to: CGPoint(x: x.target, y: max(moved.maxY, x.other.maxY))))
        }
        if let y = bestY, y.flush {
            result.guides.append(Guide(from: CGPoint(x: min(moved.minX, y.other.minX), y: y.target),
                                       to: CGPoint(x: max(moved.maxX, y.other.maxX), y: y.target)))
        }
        return result
    }

    /// 两段区间之间的空隙，重叠时为 0
    private static func gap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, max(a0, b0) - min(a1, b1))
    }

    /// 要把 bounds 往下挪多少，才不压住任何一张别的卡（隔一个网格单位，顶边仍在网格上）
    static func clearance(for bounds: CGRect, avoiding others: [CGRect]) -> CGFloat {
        var dy: CGFloat = 0
        while let hit = others.first(where: { $0.insetBy(dx: -unit / 2, dy: -unit / 2).intersects(bounds.offsetBy(dx: 0, dy: dy)) }) {
            dy = (ceil((hit.maxY + unit) / unit) * unit) - bounds.minY
        }
        return dy
    }

    /// 一组卡排成整齐的行：行宽让整体接近 16:10（常见窗口的比例），最窄也要放得下最宽的那张。aspects 是各张的高 / 宽
    static func arrange(aspects: [CGFloat], origin: CGPoint) -> [CGRect] {
        guard !aspects.isEmpty else { return [] }
        return justify(aspects: aspects, width: rowWidth(aspects), rowHeight: CGFloat(Space.rowHeight), origin: origin)
    }

    /// 这些卡排成整齐的行时用多宽的行
    static func rowWidth(_ aspects: [CGFloat]) -> CGFloat {
        let rowHeight = CGFloat(Space.rowHeight)
        let area = aspects.reduce(0) { $0 + (rowHeight + unit) * (rowHeight / $1 + unit) }
        return snap(max(sqrt(area * 1.6), aspects.map { rowHeight / $0 }.max() ?? 0))
    }

    /// 整齐排版：按顺序排成等高的行，每行恰好撑满同一宽度（最后一行不拉伸），行距、列距都是一个网格单位。
    /// 为了左右两边都齐，行高不取整到网格；整理完的卡片靠彼此的边对齐，而不是靠网格。
    /// 返回每张卡片的矩形（世界坐标），左上角从 origin 开始
    static func justify(aspects: [CGFloat], width: CGFloat, rowHeight: CGFloat, origin: CGPoint) -> [CGRect] {
        var rects: [CGRect] = []
        var row: [CGFloat] = []           // 当前行各卡片的 宽 / 高
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
