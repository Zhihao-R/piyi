import AppKit
import Library
import Tokens

/// 鼠标、触控板、键盘：选中、框选、拖动（边缘吸附、对齐线、松手吸网格）、缩放、旋转、拖到侧边栏
extension CanvasView: NSDraggingSource {
    public override var acceptsFirstResponder: Bool { true }

    /// 视图里的点（y 向下）
    func point(_ event: NSEvent) -> CGPoint { point(inWindow: event.locationInWindow) }

    func point(inWindow p: CGPoint) -> CGPoint {
        let p = convert(p, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    func worldPoint(_ p: CGPoint) -> CGPoint { camera.world(at: p, in: bounds.size) }

    func screenPoint(_ w: CGPoint) -> CGPoint { camera.view(at: w, in: bounds.size) }

    /// 某个世界坐标点上、画面里最上面的那张卡：按图层实际的叠放次序（排在幕上面的算在上面）
    func item(at w: CGPoint) -> Int64? {
        let reachable = gathering.map { Set($0.members) }
        let z = { (id: Int64) in self.live[id]?.zPosition ?? CGFloat(self.items[id]!.placement.z) }
        return index.ids(in: CGRect(origin: w, size: CGSize(width: 0.01, height: 0.01)))
            .filter { items[$0]!.contains(w) && reachable?.contains($0) != false }
            .max { z($0) < z($1) }
    }

    // MARK: 镜头

    public override func scrollWheel(with event: NSEvent) {
        stopGlide()
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 + event.scrollingDeltaY * 0.01, at: point(event))
        } else {
            camera.center.x -= event.scrollingDeltaX / camera.scale
            camera.center.y -= event.scrollingDeltaY / camera.scale
        }
    }

    /// 双指捏合：识别器给的是累计倍率，每次用完清零，下次拿到的就是这一小段
    @objc func pinched(_ r: NSMagnificationGestureRecognizer) {
        zoom(by: 1 + r.magnification, at: point(inWindow: r.location(in: nil)))
        r.magnification = 0
    }

    /// 以鼠标所在点为中心缩放
    func zoom(by factor: CGFloat, at p: CGPoint) {
        stopGlide()
        let anchor = worldPoint(p)
        let scale = min(max(camera.scale * factor, Camera.scales.lowerBound), Camera.scales.upperBound)
        camera = Camera(center: CGPoint(x: anchor.x - (p.x - bounds.width / 2) / scale,
                                        y: anchor.y - (p.y - bounds.height / 2) / scale), scale: scale)
    }

    // MARK: 悬停

    public override func mouseMoved(with event: NSEvent) {
        guard cropper == nil else { return }
        let p = point(event)
        pointer = p
        setHovered(item(at: worldPoint(p)))
        // 控件跟着悬停换；旋转钮按鼠标离得多近展开、收回
        if isEditable { updateOverlay() } else { updatePlayButtons() }
        let shelf = shelf(at: p)
        if shelf != hotShelf { hotShelf = shelf; updateShelves() }
        if origin(at: p) != nil || shelf != nil { NSCursor.pointingHand.set(); return }
        // 悬停在角标、旋转钮上时换成缩放、旋转的鼠标样式。它们排在播放钮前面：卡很小、两样叠在一起时，按下去是缩放、旋转
        if let g = handle(at: p) { cursor(for: g).set(); return }
        if playButton(at: p) != nil { NSCursor.pointingHand.set(); return }
        NSCursor.arrow.set()
    }

    public override func mouseExited(with event: NSEvent) {
        pointer = nil
        setHovered(nil)
        if hotShelf != nil { hotShelf = nil; updateShelves() }
        if isEditable { updateOverlay() } else { updatePlayButtons() }
        NSCursor.arrow.set()
    }

    private func cursor(for g: Gesture) -> NSCursor {
        switch g {
        case .resize(let r):
            // 按角在屏幕上相对卡片中心的方向选箭头，卡片转过也对
            let c = screenPoint(r.box.center), a = screenPoint(r.anchor)
            let position: NSCursor.FrameResizePosition = switch (c.x > a.x, c.y > a.y) {
            case (true, true): .bottomRight
            case (false, true): .bottomLeft
            case (true, false): .topRight
            case (false, false): .topLeft
            }
            return .frameResize(position: position, directions: .all)
        case .rotate: return Self.rotateCursor
        default: return .arrow
        }
    }

    /// 旋转的鼠标样式：系统没有，用一个旋转箭头符号画，外面描一圈白边，压在深色图片上也看得见
    static let rotateCursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return .crosshair }
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let s = symbol.size, origin = NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2)
            func draw(_ color: NSColor, at o: NSPoint) {
                let tinted = NSImage(size: s, flipped: false) { r in
                    symbol.draw(in: r)
                    color.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(at: o, from: .zero, operation: .sourceOver, fraction: 1)
            }
            for dx in [-1.0, 0, 1] { for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 { draw(.white, at: NSPoint(x: origin.x + dx, y: origin.y + dy)) } }
            draw(.black, at: origin)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 11, y: 11))
    }()

    // MARK: 按下

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event), w = worldPoint(p)
        if cropper != nil { cropDown(at: p); return }
        if let origin = origin(at: p) { delegate?.canvas(self, reveal: origin.card, on: origin.board); return }
        if let g = handle(at: p) {
            if let h = hovered { live[h]?.setLifted(false) }
            gesture = g
            return
        }
        // 音频卡上的播放钮：只管播和停，不选中、不拿起这张卡
        if let id = playButton(at: p), let item = items[id] { delegate?.canvas(self, play: item); return }
        let shift = event.modifierFlags.contains(.shift), additive = shift || event.modifierFlags.contains(.command)
        if let shelf = shelf(at: p) { selectShelf(shelf, adding: additive); return }
        guard let id = item(at: w) else {
            // 双击空白处：在这里写一张文字卡
            if event.clickCount == 2, isEditable { addNote(at: w); return }
            if spaceHeld {
                stopGlide()
                gesture = .pan(p)
            } else {
                let base = additive ? selection : []
                selection = base
                gesture = .marquee(p, p, base: base)
            }
            return
        }
        // 双击：画板里是打开这张卡（自己写的文字卡接着写），画板入口是进去。资料库和聚拢时单击就看了，轮不到双击
        if event.clickCount == 2, let item = items[id], isEditable || !Self.opensOnClick(item) { activate(item); return }
        // 画板里已经单独选中的这张再点一下：要看它（文字卡是接着写）
        let picked = selection == [id]
        if shift, browses, anchor != nil {
            // 资料库里按住 ⇧ 点：选上一段
            selection.formUnion(range(to: id))
        } else if additive {
            selection.formSymmetricDifference([id])
            anchor = id
        } else if !browses, !selection.contains(id) {
            selection = [id]
        }
        // 画板里的任务是摆：单击先选中，选中了再点才打开。资料库和聚拢的结果是用来看的：单击就放大查看
        let opens = !additive && (!isEditable || picked) && Self.opensOnClick(items[id])
        guard isEditable, selection.contains(id) else {
            // 不能挪卡的地方（资料库、聚拢中）：按住拖是带去别处（拖到侧边栏的画板上），按下没拖就松手是放大查看
            if !additive { gesture = .move(Gesture.Move(primary: id, start: p, origins: [:], top: topZ, opensOnClick: opens)) }
            return
        }
        let origins = Dictionary(uniqueKeysWithValues: selection.compactMap { items[$0].map { ($0.id, $0.placement) } })
        gesture = .move(Gesture.Move(primary: id, start: p, origins: origins, top: topZ, opensOnClick: opens))
    }

    /// 卡片能单击打开（资料库、聚拢时，画板里已选中时；按下没拖就松手）；画板入口总是双击进入
    static func opensOnClick(_ item: BoardItem?) -> Bool {
        if case .card? = item?.face { true } else { false }
    }

    /// 打开一张卡：画板里你写的文字卡是接着写，其余交给外壳（卡片放大查看、画板入口进去）
    func activate(_ item: BoardItem) {
        if item.isNote, isEditable { edit(item.id) } else { delegate?.canvas(self, open: item) }
    }

    /// 控件管的那几张：多选时是整组，否则是悬停的那张（没有悬停时是唯一选中的那张）。
    /// 框按图层当前的摆法算，拖动、缩放途中也对；旋转途中是跟着转的那个框
    func controlled() -> (ids: [Int64], box: Box)? {
        // 拖去侧边栏途中、落下后等重读时，卡在原位只是个影子：不给它画角标和旋转钮
        guard isEditable, noteEditor == nil, outgoing == nil, dimmed.isEmpty else { return nil }
        if case .rotate(let r) = gesture { return (Array(r.origins.keys), r.current) }
        let ids = selection.count > 1 ? Array(selection) : (hovered ?? selection.first).map { [$0] } ?? []
        let placements = ids.compactMap(placement)
        guard !placements.isEmpty else { return nil }
        // 一组的朝向：角度都一样就是这个角度（卡片自己记着），各不相同时才用整组转过多少
        return (ids, placements.count == 1 ? Box(placements[0]) : Box(enclosing: placements, rotation: Box.sharedRotation(of: placements) ?? groupRotation))
    }

    /// 图层上现在的摆法（拖动途中是拖到的位置）
    func placement(_ id: Int64) -> Placement? { live[id]?.item?.placement ?? items[id]?.placement }

    /// 控件画在屏幕上的四个角：拿起来的卡放大了一点，控件跟着让开
    func screenCorners(_ box: Box, _ ids: [Int64]) -> [CGPoint] {
        let k = ids.count == 1 && live[ids[0]]?.lifted == true ? CardShape.lift.scale : 1
        return box.scaled(k).corners.map(screenPoint)
    }

    /// 按在角标上缩放，按在展开的旋转钮上旋转。判定按画出来的位置，缩放、旋转按卡片本身的框
    private func handle(at p: CGPoint) -> Gesture? {
        guard let (ids, box) = controlled() else { return nil }
        let corners = box.corners, screen = screenCorners(box, ids), w = worldPoint(p)
        let origins = Dictionary(uniqueKeysWithValues: ids.compactMap { id in placement(id).map { (id, $0) } })
        if let i = Overlay.corner(at: p, of: screen) {
            let signs = [CGVector(dx: -1, dy: -1), CGVector(dx: 1, dy: -1), CGVector(dx: 1, dy: 1), CGVector(dx: -1, dy: 1)]
            return .resize(Gesture.Resize(origins: origins, box: box, corner: signs[i], anchor: corners[(i + 2) % 4],
                                          grab: CGVector(dx: w.x - corners[i].x, dy: w.y - corners[i].y),
                                          free: ids.count == 1 && items[ids[0]].map { CardArt.reflows($0.face) } == true))
        }
        if let knob = Overlay.knobCenter(of: screen), hypot(p.x - knob.x, p.y - knob.y) <= Overlay.knobSize / 2 + Overlay.slop {
            return .rotate(Gesture.Rotate(origins: origins, box: box, startAngle: atan2(w.y - box.center.y, w.x - box.center.x)))
        }
        return nil
    }

    // MARK: 拖

    public override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch gesture {
        case .none:
            break
        case .pan(let last):
            camera.center.x -= (p.x - last.x) / camera.scale
            camera.center.y -= (p.y - last.y) / camera.scale
            gesture = .pan(p)
        case .marquee(let start, _, let base):
            gesture = .marquee(start, p, base: base)
            let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            overlay.setMarquee(rect)
            let a = worldPoint(rect.origin), b = worldPoint(CGPoint(x: rect.maxX, y: rect.maxY))
            selection = base.union(index.ids(in: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)))
        case .move(var m):
            // 卡挪不了的地方：一拖就带出去；拖的是选中的那几张，按在没选中的卡上就只带这一张
            if !isEditable {
                guard hypot(p.x - m.start.x, p.y - m.start.y) > Self.dragSlop else { return }
                gesture = .none
                dragOut(selection.contains(m.primary) ? Array(selection) : [m.primary], primary: m.primary, from: [:], event: event)
                return
            }
            // 拖进侧边栏（画布铺在它底下）或拖出画布：从眼下的位置叠成一摞交给系统拖放，去选画板；原位上的卡回原处
            if !uncovered.contains(p), board != nil {
                overlay.setGuides([])
                gesture = .none
                dragOut(Array(m.origins.keys), primary: m.primary, from: m.origins.merging(m.current) { $1 }, event: event)
                display(m.origins)
                return
            }
            let starting = m.current.isEmpty
            // 手抖的一两个点不算拖：不然点一下就成了挪卡，松手还会被吸到网格上
            if starting, hypot(p.x - m.start.x, p.y - m.start.y) <= Self.dragSlop { return }
            if starting { for id in m.origins.keys { live[id]?.setLifted(false) } }
            m.current = moved(m, to: p)
            display(m.current)
            gesture = .move(m)
            updateOverlay()
            if starting { delegate?.canvasStateChanged(self) }
        case .resize(let r):
            display(r.placements(at: worldPoint(p), minWidth: Grid.unit * 2))
            // 文字类卡片边拖边重新排版，不等松手
            for id in r.origins.keys {
                if let l = live[id], let item = l.item, CardArt.reflows(item.face) { l.render(at: renderScale, files: store.files) }
            }
            updateOverlay()
            cursor(for: gesture).set()
        case .rotate(var r):
            r.turn(to: worldPoint(p), steps: event.modifierFlags.contains(.shift))
            gesture = .rotate(r)
            display(r.placements)
            updateOverlay()
            Self.rotateCursor.set()
        case .crop:
            cropDragged(to: p)
        }
    }

    /// 按下后挪过这么多点才算拖
    static let dragSlop: CGFloat = 3

    /// 拖动：手底下那张卡的边靠近邻居就吸过去并画对齐线；其余选中的卡跟着挪同样的距离
    func moved(_ m: Gesture.Move, to p: CGPoint) -> [Int64: Placement] {
        guard let primary = m.origins[m.primary] else { return m.origins }
        var offset = CGSize(width: (p.x - m.start.x) / camera.scale, height: (p.y - m.start.y) / camera.scale)
        var lines: [(CGPoint, CGPoint)] = []
        if primary.rotation == 0 {
            let proposed = primary.frame.offsetBy(dx: offset.width, dy: offset.height)
            let reach = Grid.reach / camera.scale
            let neighbors = index.ids(in: proposed.insetBy(dx: -reach, dy: -reach))
                .filter { m.origins[$0] == nil }.compactMap { items[$0]?.bounds }
            let a = Grid.align(proposed, to: neighbors, tolerance: Grid.tolerance / camera.scale, reach: reach)
            offset.width += a.offset.width
            offset.height += a.offset.height
            lines = a.guides.map { (screenPoint($0.from), screenPoint($0.to)) }
        }
        overlay.setGuides(lines)
        // 拿起来的卡叠到最上面，彼此的上下次序不变
        let order = m.origins.values.sorted { $0.z < $1.z }.map(\.id!)
        return m.origins.mapValues { o in
            var moved = o
            moved.frame = o.frame.offsetBy(dx: offset.width, dy: offset.height)
            moved.z = m.top + 1 + Double(order.firstIndex(of: o.id!)!)
            return moved
        }
    }

    // MARK: 松手

    public override func mouseUp(with event: NSEvent) {
        switch gesture {
        case .move(let m) where !m.current.isEmpty:
            overlay.setGuides([])
            commit(Array(snapped(m).values), as: String(localized: "移动"))
            gesture = .none
            delegate?.canvasStateChanged(self)
        case .move(let m):
            // 按下没拖就松手：资料库和聚拢时、画板里点已选中的那张时打开
            if m.opensOnClick, let item = items[m.primary] { activate(item) }
        case .marquee:
            overlay.setMarquee(nil)
        case .resize(let r):
            commit(Array(r.placements(at: worldPoint(point(event)), minWidth: Grid.unit * 2).values), as: String(localized: "缩放"))
        case .rotate(let r):
            if r.origins.count > 1 { groupRotation = r.current.rotation }
            commit(Array(r.placements.values), as: String(localized: "旋转"))
        case .crop:
            break
        case .none, .pan:
            break
        }
        gesture = .none
        updateOverlay()
        NSCursor.arrow.set()
    }

    /// 松手时某个方向附近没有可对齐的邻居，这个方向吸到网格（按手底下那张卡的左上角）
    private func snapped(_ m: Gesture.Move) -> [Int64: Placement] {
        guard let primary = m.current[m.primary], primary.rotation == 0 else { return m.current }
        let reach = Grid.reach / camera.scale
        let neighbors = index.ids(in: primary.frame.insetBy(dx: -reach, dy: -reach)).filter { m.origins[$0] == nil }.compactMap { items[$0]?.bounds }
        let a = Grid.align(primary.frame, to: neighbors, tolerance: 0.5 / camera.scale, reach: reach)
        let dx = a.dx == nil ? Grid.snap(primary.x) - primary.x : 0
        let dy = a.dy == nil ? Grid.snap(primary.y) - primary.y : 0
        return m.current.mapValues { var p = $0; p.frame = p.frame.offsetBy(dx: dx, dy: dy); return p }
    }

    var topZ: Double { items.values.map(\.placement.z).max() ?? 0 }

    /// 改好的摆放：更新图层和索引，写进资料库，记一步撤销。一张就只写这一行；没变的不写
    func commit(_ placements: [Placement], as name: String) {
        let changed = placements.filter { p in items[p.id!].map { $0.placement != p } ?? false }
        guard isEditable, !changed.isEmpty else { return }
        record(.moved(old: changed.map { items[$0.id!]!.placement }, new: changed), as: name)
        for p in changed {
            var item = items[p.id!]!
            item.placement = p
            items[p.id!] = item
            index.update(p.id!, item.bounds)
            if let l = live[p.id!] { refresh(l, with: item) }
        }
        // 卡可能挪进、挪出了视野：重新挑一遍要放图层的卡
        invalidateRegion()
        let store = store
        Task {
            do { try await store.update(changed); delegate?.canvasDidEdit(self, error: nil) } catch { delegate?.canvasDidEdit(self, error: error) }
        }
    }

    // MARK: 整理

    /// 把选中的卡（没选就是整个画板）排成整齐的行，旋转清零。大致保留原来从左到右、从上到下的顺序
    public func arrangeRows() {
        guard isEditable else { return }
        let targets = selection.isEmpty ? Array(items.values) : selectedItems
        guard !targets.isEmpty else { return }
        let band = { (i: BoardItem) in (i.bounds.minY / CGFloat(Space.rowHeight)).rounded() }
        let ordered = targets.sorted { band($0) != band($1) ? band($0) < band($1) : $0.bounds.minX < $1.bounds.minX }
        let origin = targets.map(\.bounds).reduce(CGRect.null) { $0.union($1) }.origin
        let rects = Grid.arrange(aspects: ordered.map { CGFloat($0.placement.height / $0.placement.width) },
                                 origin: CGPoint(x: Grid.snap(origin.x), y: Grid.snap(origin.y)))
        let placements = zip(ordered, rects).map { item, rect in
            var p = item.placement
            p.frame = rect
            p.rotation = 0
            return p
        }
        animate(placements)
        commit(placements, as: String(localized: "整理成行"))
    }

    /// 卡片换位置的动画：按设计数值里的「换位置」弹簧
    private func animate(_ placements: [Placement]) {
        for p in placements {
            guard let l = live[p.id!] else { continue }
            for (key, from, to) in [("position", NSValue(point: l.position), NSValue(point: CGPoint(x: p.frame.midX, y: p.frame.midY))),
                                    ("bounds.size", NSValue(size: l.bounds.size), NSValue(size: p.frame.size))] {
                let a = CASpringAnimation(perceptualDuration: Motion.place.response, bounce: 1 - Motion.place.damping)
                a.keyPath = key
                a.fromValue = from
                a.toValue = to
                l.add(a, forKey: key)
            }
        }
    }

    // MARK: 键盘

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: spaceHeld = true                       // 空格：按住拖空白处平移
        case 51, 117:                                     // 删除（聚拢时不删：眼前是临时摆法）
            if !selection.isEmpty, gathering == nil { delegate?.canvas(self, delete: selectedItems) }
        case 36 where cropper != nil: endCrop(commit: true)   // 回车：完成裁剪
        default: super.keyDown(with: event)
        }
    }

    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) }
    }

    @objc public override func selectAll(_ sender: Any?) { selectAll() }

    /// 取消选择（Esc、操作栏上的 ✕）。资料库里选中都是有意的，占 Esc 一层；画板里点一下就选中一张，
    /// 这一张不占，免得每次后退多按一次，框选、⌘ 点出来的多张才占。聚拢时 Esc 先收聚拢
    public func deselect() -> Bool {
        guard !selection.isEmpty, gathering == nil, browses || selection.count > 1 else { return false }
        selection = []
        return true
    }

    /// ⌘C：选中的卡记进剪贴板，到别的画板 ⌘V 放一份。聚拢时眼前是临时摆法，不记
    @objc public func copy(_ sender: Any?) {
        guard gathering == nil else { return }
        delegate?.canvas(self, copy: selectedItems)
    }

    /// ⌘V：剪贴板里的文件、图片、网址、文字收进当前视野；⌘C 记下的卡在这里放一份
    @objc public func paste(_ sender: Any?) {
        _ = delegate?.canvas(self, accept: .general, at: visibleCenter)
    }

    // MARK: 右键

    public override func menu(for event: NSEvent) -> NSMenu? {
        if let id = item(at: worldPoint(point(event))), !selection.contains(id) {
            // 资料库里点一下不动选择：右键没选中的卡，只对这一张
            if browses, let item = items[id] { return delegate?.canvasMenu(self, for: [item]) }
            selection = [id]
        }
        return selection.isEmpty ? nil : delegate?.canvasMenu(self, for: selectedItems)
    }

    // MARK: 拖出去、拖进来

    /// 拖到画布外：系统拖放带上这几条摆放的编号，侧边栏的画板认得它。
    /// 不论拖几张，跟着鼠标的都只有一张图：看得见的最上面几张叠成一小摞、标出张数，它们从眼下的位置（from，缺的按原位）
    /// 飞进这一摞。画板里是把卡带走，原位上的变淡，等落下后画布重读；没落成就复原。
    /// 出了画布缩成小图，不挡侧边栏的画板名；落进画板时缩进去消失
    private func dragOut(_ ids: [Int64], primary: Int64, from: [Int64: Placement], event: NSEvent) {
        guard let window, let placement = from[primary] ?? items[primary]?.placement else { return }
        let payload = (Self.placementsPrefix + ids.map(String.init).joined(separator: ",")) as NSString
        let p = convert(event.locationInWindow, from: nil)
        let c = screenPoint(CGPoint(x: placement.frame.midX, y: placement.frame.midY))
        // 看得见的，按住的那张在最前，其余从上往下
        let seen = camera.visibleRect(in: bounds.size)
        let at = { (id: Int64) in from[id] ?? self.items[id]?.placement }
        let shown = ([primary] + ids.filter { $0 != primary }.sorted { (at($0)?.z ?? 0) > (at($1)?.z ?? 0) })
            .lazy.compactMap { id -> (CGImage, Placement)? in
                guard let p = at(id), seen.intersects(p.frame), let image = self.live[id]?.content.contents.map({ $0 as! CGImage }) else { return nil }
                return (image, p)
            }.prefix(Outgoing.flights)
        let outgoing = Outgoing(offset: CGPoint(x: c.x - p.x, y: bounds.height - c.y - p.y), canvas: uncovered,
                                size: CGSize(width: placement.width * camera.scale, height: placement.height * camera.scale),
                                faces: shown.prefix(Outgoing.layers).map(\.0), ids: Set(ids))
        let flights = shown.map { image, p in
            let c = self.screenPoint(CGPoint(x: p.frame.midX, y: p.frame.midY))
            let size = CGSize(width: p.width * self.camera.scale, height: p.height * self.camera.scale)
            let rect = CGRect(x: c.x - size.width / 2, y: self.bounds.height - c.y - size.height / 2, width: size.width, height: size.height)
            return (image, window.convertToScreen(self.convert(rect, to: nil)))
        }
        self.outgoing = outgoing
        // 资料库里是放进一份，卡不离开，不变淡
        if isEditable { dim(Set(ids)) }
        updateOverlay()
        delegate?.canvasStateChanged(self)
        let item = NSDraggingItem(pasteboardWriter: payload)
        let drag = outgoing.drag(at: p)
        item.setDraggingFrame(drag.frame, contents: drag.image)
        beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
        Outgoing.gather(Array(flights), into: window.convertToScreen(convert(drag.top, to: nil)), over: window)
    }

    /// 原位上变淡的卡换成这几张
    func dim(_ ids: Set<Int64>) {
        let changed = dimmed.symmetricDifference(ids)
        dimmed = ids
        for id in changed { if let l = live[id] { raise(l, id) } }
    }

    /// 画布上没被侧边栏、讨论栏盖住的那一块：拖出它就是把卡带去别处
    var uncovered: CGRect {
        CGRect(x: viewport.minX, y: 0, width: viewport.width, height: bounds.height)
    }

    /// 拖出画布的摆放、拖进画布的画板，用这两个前缀的文字在拖放里传编号
    public static let placementsPrefix = "collage-placements:", boardPrefix = "collage-board:"

    /// 拖去别的画板时按住 ⌥ 是放一份，这里留着（和 Finder 一样）。光标、原位变不变淡、落下后移还是放都按它
    public static var keepsHere: Bool { NSEvent.modifierFlags.contains(.option) }

    /// 放一份时光标带上「+」
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? (Self.keepsHere ? .copy : .move) : []
    }

    public func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let outgoing, let window else { return }
        // 放一份：原位上的卡不变淡，看得出留在这里
        if isEditable { dim(Self.keepsHere ? [] : outgoing.ids) }
        let drag = outgoing.drag(at: convert(window.convertPoint(fromScreen: screenPoint), from: nil))
        session.enumerateDraggingItems(options: [], for: self, classes: [NSString.self], searchOptions: [:]) { item, _, _ in
            item.setDraggingFrame(drag.frame, contents: drag.image)
        }
    }

    /// 落进画板：系统直接收走拖动的图，这里补一张同样的图从鼠标处缩小淡出，看得出是「放进去了」。
    /// 变淡的卡留着，等画布重读时拿走或复原，免得先亮一下再消失
    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer {
            outgoing = nil
            updateOverlay()
            delegate?.canvasStateChanged(self)
        }
        guard !operation.isEmpty, let outgoing, let window else { return dim([]) }
        // 放了一份：原位上的卡留着，不等重读
        if operation == .copy { dim([]) }
        let drag = outgoing.drag(at: convert(window.convertPoint(fromScreen: screenPoint), from: nil))
        Outgoing.sink(drag.image, in: window.convertToScreen(convert(drag.frame, to: nil)), over: window)
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (sender.draggingSource as? CanvasView) === self ? [] : .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        delegate?.canvas(self, accept: sender.draggingPasteboard, at: worldPoint(point(inWindow: sender.draggingLocation))) ?? false
    }

    // MARK: 播放钮

    /// 音频卡的播放钮画在哪（屏幕点）：悬停的那张，和正在出声的那张——它不在手底下也留着，看得出声音是哪张卡的。
    /// 钮在声波那一块的正中，跟着卡片缩放；卡在屏幕上太小就不画
    func playButtons() -> [(id: Int64, center: CGPoint, size: CGFloat, pause: Bool)] {
        guard cropper == nil, outgoing == nil else { return [] }
        var ids = sounding.map { card in live.keys.filter { items[$0]?.cardID == card } } ?? []
        if let hovered, !ids.contains(hovered) { ids.append(hovered) }
        return ids.compactMap { id -> (id: Int64, center: CGPoint, size: CGFloat, pause: Bool)? in
            guard case .card(let card)? = items[id]?.face, card.kind == .audio, card.original != nil,
                  live[id]?.isHidden == false, let p = placement(id) else { return nil }
            let size: CGFloat = min(p.width * camera.scale * CardType.playMark, Overlay.playKnob.upperBound)
            guard size >= Overlay.playKnob.lowerBound else { return nil }
            // 声波那一块的中心离卡片中心多远；上下翻过的卡在另一边
            let rise = (CardArt.waveform.midY - 0.5) * (p.flipY ? -1 : 1)
            let lift = CGPoint(x: 0, y: rise * p.height).applying(CGAffineTransform(rotationAngle: p.rotation))
            return (id, screenPoint(CGPoint(x: p.frame.midX + lift.x, y: p.frame.midY + lift.y)), size, card.id == sounding)
        }
    }

    /// 屏幕点 p 落在哪张卡的播放钮上
    func playButton(at p: CGPoint) -> Int64? {
        playButtons().first { hypot(p.x - $0.center.x, p.y - $0.center.y) <= $0.size / 2 + Overlay.slop }?.id
    }

    func updatePlayButtons() {
        overlay.setPlayButtons(playButtons().map { ($0.center, $0.size, $0.pause) })
    }

    // MARK: 浮层

    func updateOverlay() {
        updatePlayButtons()
        if let cropper {
            overlay.setHandles([])
            overlay.setKnob(at: nil, open: false, owner: [])
            overlay.setReadout(nil, at: .zero)
            let a = screenPoint(cropper.full.origin), b = screenPoint(CGPoint(x: cropper.full.maxX, y: cropper.full.maxY))
            let c = screenPoint(cropper.crop.origin), d = screenPoint(CGPoint(x: cropper.crop.maxX, y: cropper.crop.maxY))
            overlay.setCrop(full: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), crop: CGRect(x: c.x, y: c.y, width: d.x - c.x, height: d.y - c.y))
            return
        }
        overlay.setCrop(full: nil, crop: nil)
        updateTags()
        updateShelves()
        guard let (ids, box) = controlled() else {
            overlay.setHandles([])
            overlay.setKnob(at: nil, open: false, owner: [])
            overlay.setReadout(nil, at: .zero)
            return
        }
        var boxes = [screenCorners(box, ids)]
        // 只选了一张、鼠标悬停在别的卡上：选中的那张也留着角标
        if selection.count == 1, let id = selection.first, ids != [id], let p = placement(id) { boxes.append(screenCorners(Box(p), [id])) }
        overlay.setHandles(boxes)
        let knob = Overlay.knobCenter(of: boxes[0])
        let rotating: Gesture.Rotate? = if case .rotate(let r) = gesture { r } else { nil }
        let near = if let pointer, let knob { hypot(pointer.x - knob.x, pointer.y - knob.y) < Overlay.knobReach } else { false }
        overlay.setKnob(at: knob, open: rotating != nil || near, owner: ids.sorted())
        overlay.setReadout(rotating.map { r in
            let a = r.current.rotation
            return "\(Int((a.wrappedAngle * 180 / .pi).rounded()))°"
        }, at: screenPoint(box.center))
    }
}

/// 正拖出画布的那几张（见 dragOut）。坐标都是视图坐标（y 向上）
struct Outgoing {
    /// 按下的地方离最上面那张卡的中心多远：在画布里缩放时按住的那一点一直在鼠标下
    let offset: CGPoint
    /// 画布在视图里没被侧边栏盖住的范围：出了它才缩小
    let canvas: CGRect
    /// 最上面那张卡在画布上的大小
    let size: CGSize
    /// 叠在那一摞里的几张卡的图，最上面的在前
    let faces: [CGImage]
    /// 拖着的是哪几张
    let ids: Set<Int64>
    var count: Int { ids.count }

    /// 出画布多远缩到最小、最小时最长边多长：比侧边栏一行略高，认得出是哪张
    static let shrinkDistance: CGFloat = 40, thumb: CGFloat = 44
    /// 一摞最多露几张、每张往右上错开多少点、张数标签多高（点，不随缩小变）
    static let layers = 3, step: CGFloat = 4, badge: CGFloat = 18
    /// 最多几张飞去叠起来：飞到一处后叠在一起分不出张数，再多只是多建图层，拖动第一帧更慢
    static let flights = 12

    /// 鼠标在 p 时跟着它的图（frame）和其中最上面那张卡的位置（top）。在画布里是原大，按住哪里就拿着哪里；
    /// 一出画布就缩成小图挪到鼠标右下，鼠标指着的那一行画板名露在外面
    func drag(at p: CGPoint) -> (frame: CGRect, top: CGRect, image: NSImage) {
        let out = max(canvas.minX - p.x, p.x - canvas.maxX, canvas.minY - p.y, p.y - canvas.maxY, 0)
        let t = min(1, out / Self.shrinkDistance)
        let k = t * t * (3 - 2 * t)
        let s = 1 - k + k * min(1, Self.thumb / max(size.width, size.height, 1))
        let card = CGSize(width: size.width * s, height: size.height * s)
        let spread = Self.step * CGFloat(max(faces.count, 1) - 1), margin = count > 1 ? Self.badge / 2 : 0
        let aside = CGPoint(x: card.width / 2 + 12, y: -card.height / 2 - 12)
        let center = CGPoint(x: p.x + (1 - k) * offset.x * s + k * aside.x, y: p.y + (1 - k) * offset.y * s + k * aside.y)
        let top = CGRect(x: center.x - card.width / 2, y: center.y - card.height / 2, width: card.width, height: card.height)
        let frame = CGRect(origin: top.origin, size: CGSize(width: card.width + spread + margin, height: card.height + spread + margin))
        return (frame, top, image(card: card, size: frame.size))
    }

    /// 一小摞：后面的往右上错开，张数标签压在这一摞的右上角上（只有一张时不标）
    private func image(card: CGSize, size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            for (i, face) in faces.enumerated().reversed() {
                let rect = CGRect(origin: CGPoint(x: Self.step * CGFloat(i), y: Self.step * CGFloat(i)), size: card)
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: -CardShape.shadow.offset), blur: CardShape.shadow.radius,
                             color: CGColor(gray: 0, alpha: CardShape.shadow.opacity))
                cg.setFillColor(Palette.card.now.cg)
                cg.fill(rect)
                cg.restoreGState()
                cg.draw(face, in: rect)
            }
            if faces.isEmpty {
                cg.setFillColor(Palette.card.now.cg)
                cg.fill(CGRect(origin: .zero, size: card))
            }
            guard count > 1 else { return true }
            let text = NSAttributedString(string: "\(count)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(cgColor: Palette.badgeInk.cg)!])
            let w = max(Self.badge, text.size().width + 12)
            let pill = CGRect(x: size.width - w, y: size.height - Self.badge, width: w, height: Self.badge)
            cg.setFillColor(Palette.badge.cg)
            cg.addPath(CGPath(roundedRect: pill, cornerWidth: Self.badge / 2, cornerHeight: Self.badge / 2, transform: nil))
            cg.fillPath()
            text.draw(at: CGPoint(x: pill.midX - text.size().width / 2, y: pill.midY - text.size().height / 2))
            return true
        }
    }

    /// 几张卡从屏幕上各自的位置飞进 target 那一张的位置，边飞边淡，到了就被拖着的那一摞接住。
    /// 按「换位置」的弹簧飞
    @MainActor static func gather(_ flights: [(CGImage, CGRect)], into target: CGRect, over parent: NSWindow) {
        guard !flights.isEmpty else { return }
        let area = flights.reduce(target) { $0.union($1.1) }
        play(in: area, over: parent) { root in
            let to = target.offsetBy(dx: -area.minX, dy: -area.minY)
            for (image, rect) in flights.reversed() {
                let layer = CALayer()
                layer.contents = image
                layer.frame = rect.offsetBy(dx: -area.minX, dy: -area.minY)
                root.addSublayer(layer)
                for (key, value) in [("position", CGPoint(x: to.midX, y: to.midY)), ("bounds.size", to.size)] as [(String, Any)] {
                    let a = CASpringAnimation(perceptualDuration: Motion.place.response, bounce: 1 - Motion.place.damping)
                    a.keyPath = key
                    a.toValue = value
                    layer.add(a, forKey: key)
                }
                layer.add(Self.fadeOut(Motion.place.response), forKey: "opacity")
                layer.opacity = 0
            }
        }
    }

    /// 一张图在屏幕上某处缩小淡出
    @MainActor static func sink(_ image: NSImage, in frame: CGRect, over parent: NSWindow) {
        play(in: frame, over: parent) { root in
            let layer = CALayer()
            layer.frame = root.bounds
            layer.contents = image
            root.addSublayer(layer)
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.toValue = 0.2
            shrink.duration = Motion.fade
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(shrink, forKey: "shrink")
            layer.add(Self.fadeOut(Motion.fade), forKey: "opacity")
            layer.opacity = 0
        }
    }

    private static func fadeOut(_ duration: Double) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        return fade
    }

    /// 在屏幕上 frame 那一块放一段临时动画：落点在画布外（侧边栏上），画布的图层够不着，
    /// 借一个透明、不接鼠标的子窗口，动画放完就收起
    @MainActor private static func play(in frame: CGRect, over parent: NSWindow, _ build: (CALayer) -> Void) {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        window.contentView = view
        parent.addChildWindow(window, ordered: .above)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            parent.removeChildWindow(window)
            window.orderOut(nil)
        }
        build(view.layer!)
        CATransaction.commit()
    }
}
