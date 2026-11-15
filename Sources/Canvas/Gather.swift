import AppKit
import QuartzCore
import Library
import Tokens

/// 聚拢：搜索和灵感的结果飞到眼前，其余卡片退成背景；退出后恢复原来的摆法。
/// 摆法都是临时的，不写资料库。来自别的画板的卡是「访客」：淡入，下面标出出处
struct Gathering {
    /// 聚拢的卡（摆放编号），按结果顺序
    var members: [Int64] = []
    /// 被挪过的本画板摆放：原来的样子，退出时飞回去
    var homes: [Int64: Placement] = [:]
    var visitors: [Int64: Visitor] = [:]
    /// 飞完了才显示出处标签，免得标签先到、卡后到
    var landed = false
}

/// 访客：临时加进来的卡
struct Visitor {
    /// 它在别的画板里的摆法和画板名；哪个画板都没放的为 nil
    var home: Home?
    /// 聚拢前的样子：比例、裁剪按它，文字类卡片的字号按它的宽度算放大倍数
    var natural: Placement
}

extension CanvasView {
    public var isGathered: Bool { gathering != nil }

    /// 有卡在原地亮着
    public var isSpotlit: Bool { !lit.isEmpty }

    /// 来自别处、还没留在当前画板的卡（卡片编号）
    public var visitingCards: [Int64] {
        guard let g = gathering else { return [] }
        return g.members.filter { g.visitors[$0] != nil }.compactMap { items[$0]?.cardID }
    }

    /// 把这些卡聚拢到眼前，按给的顺序排；已经在聚拢时换成新的一组，留下的卡直接挪到新位置。
    /// insets：视图四边被浮层（搜索栏、文字面板）占掉的宽度，卡片让开它们
    public func gather(_ cards: [Int64], insets: NSEdgeInsets) async {
        guard let content else { return }
        endCrop(commit: false)
        let need = cards.filter { resident($0) == nil && items[Self.visitorID($0)] == nil }
        let faces = (try? await store.faces(need)) ?? []
        let homes = (try? await store.homes(of: need, excluding: board)) ?? [:]
        // 等读库期间画布可能换了内容、访客可能淡出走了：以下都按等完之后的样子算，中间不再让出主线程
        guard self.content == content else { return }
        if gathering == nil { selection = [] }
        lit = []
        var state = gathering ?? Gathering()
        // 幕压在画板原有的卡上面：按它们原来的叠放顺序算，不算聚拢时临时抬高的
        veilZ = (items.values.filter { !Self.isVisitor($0.id) }.map { state.homes[$0.id]?.z ?? $0.placement.z }.max() ?? 0) + 1

        let faceByID = Dictionary(faces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let members = cards.compactMap { card -> Int64? in
            if let item = resident(card) { return item.id }
            let id = Self.visitorID(card)
            if state.visitors[id] != nil { return id }
            // 正在淡出又被要回来：停下淡出，接着当访客
            if let back = departing.removeValue(forKey: id) {
                state.visitors[id] = back
                live[id]?.stay()
                return id
            }
            guard let face = faceByID[card] else { return nil }
            var p = homes[card]?.placement ?? Placement(boardID: 0, cardID: card, frame: CGRect(origin: .zero, size: initialSize(face)), z: 0)
            p.id = id
            // 访客不是这个画板里的摆放：别的画板的「新」不带过来
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
        // 不在新结果里的本画板卡：飞回原位
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

    /// 退出聚拢：本画板的卡飞回原位，访客淡出
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

    /// 把访客留在当前画板：放在视野中央附近的空处，退出聚拢时飞过去。返回留下了几张。
    /// 先把资料库写完，再一次性换掉屏幕上的状态：写库期间鼠标、Esc、新的一组结果都可能动到它
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

    /// 写进资料库的访客换成正式的摆放编号；图层原样留着，画好的位图不用重画
    private func settle(_ placed: [(visitor: Int64, home: Placement)]) {
        guard !placed.isEmpty else { return }
        defer { delegate?.canvasDidEdit(self, error: nil) }
        record(.placed(added: placed.map(\.home), removed: []), as: String(localized: "放进当前画板"), on: .board(placed[0].home.boardID))
        // 写库期间退出了聚拢：访客已经淡出，重读一遍让留下的卡出现在画板上
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

    /// 打字时字面命中的卡原地亮起，不动位置：平时其余卡淡下去一档；聚拢时结果里没命中的淡一些。nil 或空集合表示不亮
    public func spotlight(_ cards: Set<Int64>?) {
        let hits = cards ?? []
        let pool = gathering.map { Set($0.members) } ?? Set(items.keys)
        let ids = Set(pool.filter { items[$0]?.cardID.map(hits.contains) ?? false })
        guard ids != lit else { return }
        lit = ids
        updateVeil()
    }

    /// 不在聚拢时，幕有两种用处：字面命中的卡原地亮起、多选时没选中的卡弱化；亮起优先
    func updateVeil() {
        if gathering == nil {
            veilZ = (items.values.map(\.placement.z).max() ?? 0) + 1
            setVeil(lit.isEmpty && !focusesSelection ? 0 : Palette.hint)
        }
        for (id, l) in live { raise(l, id) }
    }

    /// 选了卡：它们排在幕上面，其余的弱化。画板里单选时有角标，多选才弱化；资料库里选中只靠弱化来看出
    private var focusesSelection: Bool { isEditable ? selection.count > 1 : browses && !selection.isEmpty }

    /// 出处标签上点了一下：返回那张卡和它来自的画板
    public func origin(at p: CGPoint) -> (card: Int64, board: Int64)? {
        guard let state = gathering, state.landed, let id = overlay.tag(at: p),
              let home = state.visitors[id]?.home, let card = items[id]?.cardID else { return nil }
        return (card, home.placement.boardID)
    }

    /// 镜头对准某张卡（从出处标签跳过来时用）
    public func focus(card: Int64) {
        guard let item = resident(card) else { return }
        focus(item.id)
    }

    // MARK: 内部

    /// 访客的临时编号：不和画板里的摆放（正数）、几种卡片视图的临时摆放（卡片编号的相反数）撞上
    static func visitorID(_ card: Int64) -> Int64 { -(1 << 40) - card }
    static func isVisitor(_ id: Int64) -> Bool { id <= -(1 << 40) }

    /// 这张卡在当前画布上本来就有的那一条（不算访客）；同一张卡摆了几次时取最上面的
    private func resident(_ card: Int64) -> BoardItem? {
        items.values.filter { !Self.isVisitor($0.id) && $0.cardID == card }.max { $0.placement.z < $1.placement.z }
    }

    private func initialSize(_ face: CardFace) -> CGSize {
        CardSize.initial(kind: face.kind, coverAspect: face.cover.flatMap { CardSize.coverAspect($0, files: store.files) },
                         text: face.isOwnText ? face.excerpt : nil, hasBody: face.length > 0)
    }

    /// 在屏幕上排好，换回世界坐标：卡片之间的空隙在屏幕上恒定，不随缩放变化。
    /// 画布铺到侧边栏和标题栏底下，被它们盖住的部分也要让开
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

    /// 摆放变了的卡从原来的样子飞到新位置（FLIP：图层直接放到终点，只动画变换）；新来的访客淡入。
    /// wasLive：改摆放之前就有图层的卡，从屏幕上现在的样子起飞；其余的（视野外飞进来的）从原来的摆法起飞
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

    /// 访客离开：淡出后移走。淡出期间又被要回去时，gather 会把它从 departing 里取回
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

    /// 排在幕的上面：亮起的卡、多选中的卡、正在飞的卡（飞回原位途中幕在淡出，压在下面会跟着发灰）。
    /// 悬停不改叠放次序：压在大卡上的小卡要一直点得到。
    /// 聚拢时又打字：结果里没命中的淡一些；正拖去侧边栏的，原位上的更淡
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

    /// 出处标签：访客飞到位以后，在卡片左下角下方标出它来自哪个画板
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
