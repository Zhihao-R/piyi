import AppKit
import QuartzCore
import Library
import Tokens

/// Gathering: search and inspiration results fly up front and the other cards recede into the background; on exit the original arrangement is restored.
/// The arrangement is temporary and not written to the library. Cards from other boards are "visitors": they fade in, with their source marked below
struct Gathering {
    /// Gathered cards (placement IDs), in result order
    var members: [Int64] = []
    /// Placements on this board that were moved: their original state, to fly back to on exit
    var homes: [Int64: Placement] = [:]
    var visitors: [Int64: Visitor] = [:]
    /// Source labels show only after the flight finishes, so a label doesn't arrive before its card
    var landed = false
}

/// Visitors: cards temporarily added
struct Visitor {
    /// Its placement on another board and that board's name; nil when it isn't on any board
    var home: Home?
    /// How it looked before gathering: ratio and crop follow it, and for text cards the enlargement factor is computed from its width
    var natural: Placement
}

extension CanvasView {
    public var isGathered: Bool { gathering != nil }

    /// Some cards are lit up in place
    public var isSpotlit: Bool { !lit.isEmpty }

    /// Cards from elsewhere not yet kept on the current board (card IDs)
    public var visitingCards: [Int64] {
        guard let g = gathering else { return [] }
        return g.members.filter { g.visitors[$0] != nil }.compactMap { items[$0]?.cardID }
    }

    /// Gathers these cards up front, in the given order; when already gathering, switches to the new set, and cards that remain move straight to their new positions.
    /// insets: widths on each side of the view taken by overlays (search bar, text panel); cards keep clear of them
    public func gather(_ cards: [Int64], insets: NSEdgeInsets) async {
        guard let content else { return }
        endCrop(commit: false)
        let need = cards.filter { resident($0) == nil && items[Self.visitorID($0)] == nil }
        let faces = (try? await store.faces(need)) ?? []
        let homes = (try? await store.homes(of: need, excluding: board)) ?? [:]
        // While waiting on the library the canvas may have switched content and visitors may have faded out: everything below works from the state after the wait, without yielding the main thread again
        guard self.content == content else { return }
        if gathering == nil { selection = [] }
        lit = []
        var state = gathering ?? Gathering()
        // The scrim sits above the board's existing cards: by their original stacking order, not the temporary raise from gathering
        veilZ = (items.values.filter { !Self.isVisitor($0.id) }.map { state.homes[$0.id]?.z ?? $0.placement.z }.max() ?? 0) + 1

        let faceByID = Dictionary(faces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let members = cards.compactMap { card -> Int64? in
            if let item = resident(card) { return item.id }
            let id = Self.visitorID(card)
            if state.visitors[id] != nil { return id }
            // Was fading out and requested again: stop fading and carry on as a visitor
            if let back = departing.removeValue(forKey: id) {
                state.visitors[id] = back
                live[id]?.stay()
                return id
            }
            guard let face = faceByID[card] else { return nil }
            var p = homes[card]?.placement ?? Placement(boardID: 0, cardID: card, frame: CGRect(origin: .zero, size: initialSize(face)), z: 0)
            p.id = id
            // Visitors aren't placements on this board: "New" from other boards isn't carried over
            p.unseen = false
            items[id] = BoardItem(placement: p, face: .card(face))
            state.visitors[id] = Visitor(home: homes[card], natural: p)
            return id
        }
        for (id, visitor) in state.visitors where !members.contains(id) {
            state.visitors[id] = nil
            depart(id, visitor)
        }
        let wasLive = Set(live.keys)
        let fresh = Set(members.filter { state.visitors[$0] != nil && live[$0] == nil })
        var from: [Int64: Placement] = [:]
        // Cards on this board not in the new results: fly back to their original positions
        for (id, home) in state.homes where !members.contains(id) {
            from[id] = items[id]?.placement
            items[id]?.placement = home
            items[id]?.zoom = 1
            state.homes[id] = nil
        }
        for (id, rect) in zip(members, layout(members, insets: insets, state: state)) {
            guard var item = items[id] else { continue }
            if state.visitors[id] == nil, state.homes[id] == nil { state.homes[id] = item.placement }
            if !fresh.contains(id) { from[id] = item.placement }
            let natural = state.homes[id] ?? state.visitors[id]!.natural
            item.placement.frame = rect
            item.placement.rotation = 0
            item.placement.z = veilZ + 1 + Double(members.firstIndex(of: id)!)
            item.zoom = rect.width / natural.width
            items[id] = item
        }
        state.members = members
        state.landed = false
        gathering = state
        rebuildIndex()
        stage(from: from, fadeIn: fresh, wasLive: wasLive)
        setVeil(Palette.recede)
    }

    /// Exit gathering: this board's cards fly back to their original positions, visitors fade out
    public func scatter() {
        guard let state = gathering else { return }
        let wasLive = Set(live.keys)
        var from: [Int64: Placement] = [:]
        for (id, home) in state.homes {
            from[id] = items[id]?.placement
            items[id]?.placement = home
            items[id]?.zoom = 1
        }
        for (id, visitor) in state.visitors { depart(id, visitor) }
        gathering = nil
        lit = []
        selection = []
        rebuildIndex()
        stage(from: from, fadeIn: [], wasLive: wasLive)
        setVeil(0)
        overlay.setTags([])
        if needsReload { needsReload = false; Task { try? await reload() } }
    }

    /// Keep the visitors on the current board: placed in free space near the center of the view, flying there when gathering ends. Returns how many were kept.
    /// Finish writing to the library first, then swap the on-screen state all at once: during the write, the mouse, Esc, or a new set of results could all touch it
    @discardableResult
    public func keepVisitors(_ cards: [Int64]? = nil) async throws -> [Int64] {
        guard let state = gathering, let board else { return [] }
        let chosen = state.members.filter { id in state.visitors[id] != nil && (cards.map { c in items[id]?.cardID.map(c.contains) ?? false } ?? true) }
        guard !chosen.isEmpty else { return [] }
        let taken = items.values.filter { !Self.isVisitor($0.id) }.map { state.homes[$0.id].map(\.frame) ?? $0.bounds }
        let natural = chosen.map { state.visitors[$0]!.natural }
        let frames = Layout.arranged(natural.map(\.frame.size), from: CGPoint(x: camera.center.x - natural[0].width / 2, y: camera.center.y), avoiding: taken)
        let homes = try await store.place(zip(natural, frames).map { n, frame in
            var home = Placement(boardID: board, cardID: n.cardID, frame: frame, z: 0)
            home.crop = n.crop
            return home
        })
        settle(Array(zip(chosen, homes)))
        return homes.compactMap(\.cardID)
    }

    /// Visitors written to the library get proper placement IDs; the layers stay as they are and drawn bitmaps needn't be redrawn
    private func settle(_ placed: [(visitor: Int64, home: Placement)]) {
        guard !placed.isEmpty else { return }
        defer { delegate?.canvasDidEdit(self, error: nil) }
        record(.placed(added: placed.map(\.home), removed: []), as: String(localized: "放进当前画板"), on: .board(placed[0].home.boardID))
        // Gathering was exited during the library write: visitors have already faded out, so reload to make the kept cards appear on the board
        guard var state = gathering else { Task { try? await reload() }; return }
        for (id, home) in placed {
            guard state.visitors.removeValue(forKey: id) != nil, var item = items.removeValue(forKey: id) else { continue }
            item.placement.id = home.id
            item.placement.boardID = home.boardID
            item.zoom = item.placement.width / home.width
            items[home.id!] = item
            if let l = live.removeValue(forKey: id) { l.place(item.placement); live[home.id!] = l }
            state.homes[home.id!] = home
            state.members = state.members.map { $0 == id ? home.id! : $0 }
        }
        gathering = state
        rebuildIndex()
        updateOverlay()
    }

    /// While typing, cards that literally match light up in place without moving: normally the other cards dim one step; while gathering, results that don't match dim somewhat. nil or an empty set means nothing is lit
    public func spotlight(_ cards: Set<Int64>?) {
        let hits = cards ?? []
        let pool = gathering.map { Set($0.members) } ?? Set(items.keys)
        let ids = Set(pool.filter { items[$0]?.cardID.map(hits.contains) ?? false })
        guard ids != lit else { return }
        lit = ids
        updateVeil()
    }

    /// When not gathering, the scrim has two uses: lighting up literal matches in place, and de-emphasizing unselected cards during multi-select; lighting up takes priority
    func updateVeil() {
        if gathering == nil {
            veilZ = (items.values.map(\.placement.z).max() ?? 0) + 1
            setVeil(lit.isEmpty && !focusesSelection ? 0 : Palette.hint)
        }
        for (id, l) in live { raise(l, id) }
    }

    /// Cards are selected: they sit above the scrim and the rest are de-emphasized. On a board a single selection has badges and only multi-select de-emphasizes; in the library selection shows only through de-emphasis
    private var focusesSelection: Bool { isEditable ? selection.count > 1 : browses && !selection.isEmpty }

    /// A click on a source label: returns that card and the board it came from
    public func origin(at p: CGPoint) -> (card: Int64, board: Int64)? {
        guard let state = gathering, state.landed, let id = overlay.tag(at: p),
              let home = state.visitors[id]?.home, let card = items[id]?.cardID else { return nil }
        return (card, home.placement.boardID)
    }

    /// Point the camera at a card (used when jumping from a source label)
    public func focus(card: Int64) {
        guard let item = resident(card) else { return }
        focus(item.id)
    }

    // MARK: Internal

    /// Temporary IDs for visitors: don't collide with placements on boards (positive) or temporary placements of the card views (negated card IDs)
    static func visitorID(_ card: Int64) -> Int64 { -(1 << 40) - card }
    static func isVisitor(_ id: Int64) -> Bool { id <= -(1 << 40) }

    /// The placement this card already has on the current canvas (not visitors); when the same card is placed several times, take the topmost
    private func resident(_ card: Int64) -> BoardItem? {
        items.values.filter { !Self.isVisitor($0.id) && $0.cardID == card }.max { $0.placement.z < $1.placement.z }
    }

    private func initialSize(_ face: CardFace) -> CGSize {
        CardSize.initial(kind: face.kind, coverAspect: face.cover.flatMap { CardSize.coverAspect($0, files: store.files) },
                         text: face.isOwnText ? face.excerpt : nil, hasBody: face.length > 0)
    }

    /// Lay out on screen, then convert back to world coordinates: gaps between cards stay constant on screen regardless of zoom.
    /// The canvas extends under the sidebar and title bar, so the parts they cover must be kept clear too
    private func layout(_ members: [Int64], insets: NSEdgeInsets, state: Gathering) -> [CGRect] {
        let s = covered, m = CGFloat(Chrome.inset) * 2
        let area = CGRect(x: s.left + insets.left + m, y: s.top + insets.top + m,
                          width: bounds.width - s.left - s.right - insets.left - insets.right - m * 2,
                          height: bounds.height - s.top - s.bottom - insets.top - insets.bottom - m * 2)
        let aspects = members.map { id in
            let n = state.homes[id] ?? state.visitors[id]?.natural ?? items[id]!.placement
            return CGFloat(n.height / n.width)
        }
        return Layout.gathered(aspects: aspects, in: area).map { r in
            CGRect(origin: worldPoint(r.origin), size: CGSize(width: r.width / camera.scale, height: r.height / camera.scale))
        }
    }

    func rebuildIndex() {
        index = SpatialIndex(items.mapValues(\.bounds))
        invalidateRegion()
    }

    /// Cards whose placement changed fly from their original look to the new position (FLIP: the layer goes straight to its destination and only the transform animates); newly arrived visitors fade in.
    /// wasLive: cards that had a layer before the placement change take off from how they look on screen now; the others (flying in from outside the view) take off from their original placement
    func stage(from: [Int64: Placement], fadeIn: Set<Int64>, wasLive: Set<Int64>) {
        for (id, old) in from {
            guard let item = items[id], let l = live[id] ?? adopt(id) else { continue }
            flying.insert(id)
            let start = wasLive.contains(id) ? l.pose : l.pose(of: old)
            refresh(l, with: item)
            l.fly(from: start)
        }
        for id in fadeIn { (live[id] ?? adopt(id))?.appear() }
        for (id, l) in live { raise(l, id) }
        let generation = UUID()
        landing = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.place.response * 1.6) { [weak self] in
            guard let self, landing == generation else { return }
            flying = []
            gathering?.landed = true
            for (id, l) in live { raise(l, id) }
            invalidateRegion()
        }
    }

    /// A visitor leaves: fades out and is then removed. If requested again during the fade, gather takes it back out of departing
    private func depart(_ id: Int64, _ visitor: Visitor) {
        guard let l = live[id] else { items[id] = nil; return }
        departing[id] = visitor
        flying.insert(id)
        l.vanish { [weak self] in
            guard let self, departing.removeValue(forKey: id) != nil else { return }
            items[id] = nil
            flying.remove(id)
            if let l = live.removeValue(forKey: id) { recycle(l) }
            rebuildIndex()
        }
    }

    /// Above the scrim: lit-up cards, multi-selected cards, cards in flight (the scrim fades out while they fly back, so beneath it they'd go gray with it).
    /// Hover doesn't change stacking order: a small card on top of a large one must stay clickable.
    /// Typing again while gathering: results that don't match dim somewhat; while being dragged to the sidebar, the one left in place dims more
    func raise(_ l: CardLayer, _ id: Int64) {
        guard let p = l.item?.placement ?? items[id]?.placement else { return }
        let above = flying.contains(id) || gathering == nil && (lit.isEmpty ? focusesSelection && selection.contains(id) : lit.contains(id))
        l.zPosition = above ? veilZ + 1 + p.z : p.z
        let faded = !lit.isEmpty && !lit.contains(id) && gathering?.members.contains(id) == true
        l.opacity = dimmed.contains(id) ? Float(1 - Palette.recede) : faded ? Float(1 - Palette.hint) : 1
    }

    private func setVeil(_ target: Double) {
        veil.zPosition = veilZ
        guard veil.opacity != Float(target) else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = veil.presentation()?.opacity ?? veil.opacity
        fade.duration = Motion.fade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        veil.opacity = Float(target)
        veil.add(fade, forKey: "opacity")
    }

    /// Source label: once a visitor has flown into place, marks which board it came from below the card's bottom-left corner
    func updateTags() {
        guard let state = gathering, state.landed else { overlay.setTags([]); return }
        overlay.setTags(state.members.compactMap { id in
            guard let visitor = state.visitors[id], let item = items[id] else { return nil }
            let corner = screenPoint(CGPoint(x: item.placement.frame.minX, y: item.placement.frame.maxY))
            return (id, visitor.home.map { String(localized: "来自「\($0.boardName)」") } ?? String(localized: "未放进画板"), CGPoint(x: corner.x, y: corner.y + 6))
        })
    }
}

extension BoardItem {
    var cardID: Int64? { placement.cardID }
}
