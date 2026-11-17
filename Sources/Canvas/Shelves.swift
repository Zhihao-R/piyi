import AppKit
import Library
import Tokens

/// How the card views (all cards, unsorted, trash) are grouped. The grouping rules come from the App:
/// color names and site names live in other modules; the canvas only lays out the groups and writes their titles
public struct Grouping: Sendable {
    /// A group: title, sort position (smaller first; ties go to the one with more cards)
    public struct Group: Hashable, Sendable {
        public var title: String
        public var rank: Double
        public init(title: String, rank: Double = 0) { (self.title, self.rank) = (title, rank) }
    }

    public var group: @Sendable (CardFace) -> Group
    public init(_ group: @escaping @Sendable (CardFace) -> Group) { self.group = group }
}

/// A laid-out group: title, the cards in it (placement IDs, in on-screen order), and the top-left corner of the title area in world coordinates
struct Shelf: Equatable {
    var title: String
    var members: [Int64]
    var origin: CGPoint
}

extension CanvasView {
    /// Views that aren't boards: newest collected first; when grouped, cards of a group stay together and groups follow the given order.
    /// Placements are temporary; IDs are the negated card IDs, and the stacking order is the on-screen order (⇧ range selection uses it)
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
        // No grouping means one whole group with no title: laid out downward like a long page, same as when grouped
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

    /// In the library a click only looks and leaves the selection alone; select with ⌘-click, ⇧-click, marquee, or group titles
    public var browses: Bool { !isEditable && gathering == nil }

    /// ⇧-click in the library: from the last clicked card to this one, in on-screen order
    func range(to id: Int64) -> Set<Int64> {
        let order = items.values.sorted { $0.placement.z < $1.placement.z }.map(\.id)
        guard let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) else { return [id] }
        return Set(order[min(a, b)...max(a, b)])
    }

    /// Clicking a group title: selects that group; with ⇧ or ⌘ held, adds it to the selection
    func selectShelf(_ i: Int, adding: Bool) {
        let ids = Set(shelves[i].members)
        selection = adding ? selection.union(ids) : ids
        anchor = shelves[i].members.first
    }

    /// Which group's title screen point p falls on
    func shelf(at p: CGPoint) -> Int? { overlay.shelf(at: p) }

    /// Group titles are written at the top left of each group and follow the camera; only the visible groups are written. Not written while gathering, while cards are flying, or when zoomed too far out
    func updateShelves() {
        // The new scene is still hidden behind the curtain: keep the old scene's titles and swap them together when it comes up (see Swap.swift)
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
