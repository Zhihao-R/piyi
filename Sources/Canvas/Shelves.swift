import AppKit
import Library
import Tokens

/// 几种卡片视图（全部卡片、未归类、废纸篓）按什么分组。分组规则由 App 给：
/// 颜色名、网站的叫法在别的块里，画布只管按组排开、写标题
public struct Grouping: Sendable {
    /// 一组：标题，排第几（小的在前；一样的按张数多的在前）
    public struct Group: Hashable, Sendable {
        public var title: String
        public var rank: Double
        public init(title: String, rank: Double = 0) { (self.title, self.rank) = (title, rank) }
    }

    public var group: @Sendable (CardFace) -> Group
    public init(_ group: @escaping @Sendable (CardFace) -> Group) { self.group = group }
}

/// 排出来的一组：标题、组里的卡（摆放编号，按眼前的顺序）、标题区在世界坐标里的左上角
struct Shelf: Equatable {
    var title: String
    var members: [Int64]
    var origin: CGPoint
}

extension CanvasView {
    /// 不属于画板的视图：按收集时间从新到旧；分组时同组的排在一起，组按给的次序。
    /// 摆放是临时的，编号用卡片编号的相反数，叠放次序就是眼前的顺序（⇧ 选一段按它算）
    nonisolated static func lay(_ cards: [(face: CardFace, size: CGSize?)], grouping: Grouping?, files: FileStore, width: CGFloat = Layout.shelfWidth) -> (items: [BoardItem], shelves: [Shelf]) {
        let aspects = cards.map { card in
            let size = card.size ?? CardSize.initial(kind: card.face.kind, coverAspect: card.face.cover.flatMap { CardSize.coverAspect($0, files: files) },
                                                     text: card.face.isOwnText ? card.face.excerpt : nil, hasBody: card.face.length > 0)
            return size.height / size.width
        }
        let item = { (i: Int, rect: CGRect, z: Int) -> BoardItem in
            var p = Placement(boardID: 0, cardID: cards[i].face.id, frame: rect, z: Double(z))
            p.id = -cards[i].face.id
            return BoardItem(placement: p, face: .card(cards[i].face))
        }
        // 不分组就是一整组、不写标题：和分组时一样像一页长文往下排
        let keys = cards.map { grouping?.group($0.face) ?? Grouping.Group(title: "") }
        var members: [Grouping.Group: [Int]] = [:]
        for (i, key) in keys.enumerated() { members[key, default: []].append(i) }
        let groups = members.keys.sorted { a, b in
            a.rank != b.rank ? a.rank < b.rank : members[a]!.count != members[b]!.count ? members[a]!.count > members[b]!.count : members[a]![0] < members[b]![0]
        }
        let laid = Layout.shelves(groups.map { members[$0]!.map { aspects[$0] } }, width: width)
        var items: [BoardItem] = [], shelves: [Shelf] = []
        for (group, (title, rects)) in zip(groups, laid) {
            let start = items.count
            items += zip(members[group]!, rects).enumerated().map { k, pair in item(pair.0, pair.1, start + k) }
            if grouping != nil { shelves.append(Shelf(title: group.title, members: items[start...].map(\.id), origin: title)) }
        }
        return (items, shelves)
    }

    /// 资料库里点一下只是看，不动选择；选择靠 ⌘ 点、⇧ 点、框选、分组标题
    public var browses: Bool { !isEditable && gathering == nil }

    /// 资料库里按住 ⇧ 点：从上次点的那张到这张，按眼前的顺序
    func range(to id: Int64) -> Set<Int64> {
        let order = items.values.sorted { $0.placement.z < $1.placement.z }.map(\.id)
        guard let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) else { return [id] }
        return Set(order[min(a, b)...max(a, b)])
    }

    /// 点分组标题：选中这一组；按着 ⇧ 或 ⌘ 是加进已选的
    func selectShelf(_ i: Int, adding: Bool) {
        let ids = Set(shelves[i].members)
        selection = adding ? selection.union(ids) : ids
        anchor = shelves[i].members.first
    }

    /// 屏幕点 p 落在哪一组的标题上
    func shelf(at p: CGPoint) -> Int? { overlay.shelf(at: p) }

    /// 分组标题写在每组左上方，跟着镜头走；只写看得见的几组。聚拢、卡片正在飞、缩得太小时不写
    func updateShelves() {
        // 新画面还藏在幕布后面：标题留着旧画面的，换上来时再一起换（见 Swap.swift）
        guard !isBehindCurtain else { return }
        guard gathering == nil, flying.isEmpty, camera.scale >= Self.shadowScale else { overlay.setShelves([], dark: isDark); return }
        let visible = camera.visibleRect(in: bounds.size)
        overlay.setShelves(shelves.indices.compactMap { i in
            let s = shelves[i], top = s.origin.y + Layout.shelfTitle
            guard top > visible.minY, s.origin.y < visible.maxY else { return nil }
            let at = screenPoint(CGPoint(x: s.origin.x, y: top))
            return (i, s.title, String(localized: "\(s.members.count) 张卡") + (i == hotShelf ? String(localized: "　选中这一组") : ""), CGPoint(x: at.x, y: at.y - 8))
        }, dark: isDark)
    }

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
