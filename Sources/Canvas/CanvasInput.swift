import AppKit
import Library
import Tokens

/// Mouse, trackpad, keyboard: select, marquee, drag (edge snapping, guides, snap to grid on release), resize, rotate, drag to the sidebar
extension CanvasView: NSDraggingSource {
    public override var acceptsFirstResponder: Bool { true }

    /// A point in the view (y down)
    func point(_ event: NSEvent) -> CGPoint { point(inWindow: event.locationInWindow) }

    func point(inWindow p: CGPoint) -> CGPoint {
        let p = convert(p, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    func worldPoint(_ p: CGPoint) -> CGPoint { camera.world(at: p, in: bounds.size) }

    func screenPoint(_ w: CGPoint) -> CGPoint { camera.view(at: w, in: bounds.size) }

    /// The topmost card in the picture at a world point: by the layers' actual stacking order (cards above the scrim count as on top)
    func item(at w: CGPoint) -> Int64? {
        let reachable = gathering.map { Set($0.members) }
        let z = { (id: Int64) in self.live[id]?.zPosition ?? CGFloat(self.items[id]!.placement.z) }
        return index.ids(in: CGRect(origin: w, size: CGSize(width: 0.01, height: 0.01)))
            .filter { items[$0]!.contains(w) && reachable?.contains($0) != false }
            .max { z($0) < z($1) }
    }

    // MARK: Camera

    public override func scrollWheel(with event: NSEvent) {
        stopGlide()
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 + event.scrollingDeltaY * 0.01, at: point(event))
        } else {
            camera.center.x -= event.scrollingDeltaX / camera.scale
            camera.center.y -= event.scrollingDeltaY / camera.scale
        }
    }

    /// Pinch: the recognizer gives a cumulative magnification, reset after each use, so the next one is just this small step
    @objc func pinched(_ r: NSMagnificationGestureRecognizer) {
        zoom(by: 1 + r.magnification, at: point(inWindow: r.location(in: nil)))
        r.magnification = 0
    }

    /// Zoom centered on the mouse location
    func zoom(by factor: CGFloat, at p: CGPoint) {
        stopGlide()
        let anchor = worldPoint(p)
        let scale = min(max(camera.scale * factor, Camera.scales.lowerBound), Camera.scales.upperBound)
        camera = Camera(center: CGPoint(x: anchor.x - (p.x - bounds.width / 2) / scale,
                                        y: anchor.y - (p.y - bounds.height / 2) / scale), scale: scale)
    }

    // MARK: Hover

    public override func mouseMoved(with event: NSEvent) {
        guard cropper == nil else { return }
        let p = point(event)
        pointer = p
        setHovered(item(at: worldPoint(p)))
        // Controls follow the hover; the rotate knob expands and collapses by how close the mouse is
        if isEditable { updateOverlay() } else { updatePlayButtons() }
        let shelf = shelf(at: p)
        if shelf != hotShelf { hotShelf = shelf; updateShelves() }
        if origin(at: p) != nil || shelf != nil { NSCursor.pointingHand.set(); return }
        // Over a corner handle or the rotate knob, switch to the resize or rotate cursor. They take precedence over the play button: when a card is small and they overlap, pressing resizes or rotates
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
            // Choose the arrow by the corner's on-screen direction from the card center, so it's right for rotated cards too
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

    /// Rotate cursor: the system has none, so draw a rotating-arrow symbol with a white outline, visible even over dark images
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

    // MARK: Mouse down

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
        // Play button on audio cards: only plays and stops, doesn't select or lift the card
        if let id = playButton(at: p), let item = items[id] { delegate?.canvas(self, play: item); return }
        let shift = event.modifierFlags.contains(.shift), additive = shift || event.modifierFlags.contains(.command)
        if let shelf = shelf(at: p) { selectShelf(shelf, adding: additive); return }
        guard let id = item(at: w) else {
            // Double-click on empty space: write a text card here
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
        // Double-click: on a board it opens the card (text cards you wrote continue editing); on a board entry it goes in. In the library and while gathering a single click already views it, so double-click never gets a turn
        if event.clickCount == 2, let item = items[id], isEditable || !Self.opensOnClick(item) { activate(item); return }
        // Clicking again on the card that's already the only one selected on a board: view it (text cards continue editing)
        let picked = selection == [id]
        if shift, browses, anchor != nil {
            // ⇧-click in the library: select a range
            selection.formUnion(range(to: id))
        } else if additive {
            selection.formSymmetricDifference([id])
            anchor = id
        } else if !browses, !selection.contains(id) {
            selection = [id]
        }
        // On a board the job is arranging: a single click selects first, and clicking the selected card opens it. Library and gathering results are for viewing: a single click opens detail view
        let opens = !additive && (!isEditable || picked) && Self.opensOnClick(items[id])
        guard isEditable, selection.contains(id) else {
            // Where cards can't be moved (library, while gathering): press and drag takes them elsewhere (onto a board in the sidebar); press and release without dragging opens detail view
            if !additive { gesture = .move(Gesture.Move(primary: id, start: p, origins: [:], top: topZ, opensOnClick: opens)) }
            return
        }
        let origins = Dictionary(uniqueKeysWithValues: selection.compactMap { items[$0].map { ($0.id, $0.placement) } })
        gesture = .move(Gesture.Move(primary: id, start: p, origins: origins, top: topZ, opensOnClick: opens))
    }

    /// Cards open with a single click (in the library, while gathering, or when already selected on a board; press and release without dragging); board entries always open with a double-click
    static func opensOnClick(_ item: BoardItem?) -> Bool {
        if case .card? = item?.face { true } else { false }
    }

    /// Open a card: on a board, a text card you wrote continues editing; everything else goes to the shell (cards open detail view, board entries go in)
    func activate(_ item: BoardItem) {
        if item.isNote, isEditable { edit(item.id) } else { delegate?.canvas(self, open: item) }
    }

    /// The cards the controls apply to: the whole group when multi-selected, otherwise the hovered card (or the only selected one when nothing is hovered).
    /// The frame is computed from the layers' current placement, so it's right mid-drag and mid-resize too; mid-rotation it's the frame rotating along
    func controlled() -> (ids: [Int64], box: Box)? {
        // While being dragged to the sidebar, and after dropping while waiting for the reload, the card in place is only a ghost: don't draw corner handles or the rotate knob for it
        guard isEditable, noteEditor == nil, outgoing == nil, dimmed.isEmpty else { return nil }
        if case .rotate(let r) = gesture { return (Array(r.origins.keys), r.current) }
        let ids = selection.count > 1 ? Array(selection) : (hovered ?? selection.first).map { [$0] } ?? []
        let placements = ids.compactMap(placement)
        guard !placements.isEmpty else { return nil }
        // A group's orientation: if all angles are equal, that angle (each card remembers its own); only when they differ use how far the whole group has rotated
        return (ids, placements.count == 1 ? Box(placements[0]) : Box(enclosing: placements, rotation: Box.sharedRotation(of: placements) ?? groupRotation))
    }

    /// The placement on the layers now (mid-drag, the dragged-to position)
    func placement(_ id: Int64) -> Placement? { live[id]?.item?.placement ?? items[id]?.placement }

    /// The four corners of the controls on screen: a lifted card is slightly enlarged, so the controls move out of the way
    func screenCorners(_ box: Box, _ ids: [Int64]) -> [CGPoint] {
        let k = ids.count == 1 && live[ids[0]]?.lifted == true ? CardShape.lift.scale : 1
        return box.scaled(k).corners.map(screenPoint)
    }

    /// Press on a corner handle to resize, on the expanded rotate knob to rotate. Hit testing uses the drawn positions; resizing and rotating use the card's own frame
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

    // MARK: Drag

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
            // Where cards can't be moved: dragging takes them out right away; it drags the selected cards, or just this one if pressed on an unselected card
            if !isEditable {
                guard hypot(p.x - m.start.x, p.y - m.start.y) > Self.dragSlop else { return }
                gesture = .none
                dragOut(selection.contains(m.primary) ? Array(selection) : [m.primary], primary: m.primary, from: [:], event: event)
                return
            }
            // Dragged into the sidebar (the canvas extends under it) or off the canvas: stack them up from where they are now and hand them to system drag and drop to pick a board; the cards in place return to where they were
            if !uncovered.contains(p), board != nil {
                overlay.setGuides([])
                gesture = .none
                dragOut(Array(m.origins.keys), primary: m.primary, from: m.origins.merging(m.current) { $1 }, event: event)
                display(m.origins)
                return
            }
            let starting = m.current.isEmpty
            // A shake of a point or two isn't a drag: otherwise a click would move the card, and it would snap to the grid on release
            if starting, hypot(p.x - m.start.x, p.y - m.start.y) <= Self.dragSlop { return }
            if starting { for id in m.origins.keys { live[id]?.setLifted(false) } }
            m.current = moved(m, to: p)
            display(m.current)
            gesture = .move(m)
            updateOverlay()
            if starting { delegate?.canvasStateChanged(self) }
        case .resize(let r):
            display(r.placements(at: worldPoint(p), minWidth: Grid.unit * 2))
            // Text cards relay out while being dragged, without waiting for release
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

    /// How many points the mouse must move after pressing to count as a drag
    static let dragSlop: CGFloat = 3

    /// Dragging: when an edge of the card under the pointer nears a neighbor it snaps to it and draws a guide; the other selected cards move the same distance
    func moved(_ m: Gesture.Move, to p: CGPoint) -> [Int64: Placement] {
        guard let primary = m.origins[m.primary] else { return m.origins }
        var offset = CGSize(width: (p.x - m.start.x) / camera.scale, height: (p.y - m.start.y) / camera.scale)
        var lines: [Grid.Guide] = []
        if primary.rotation == 0 {
            let proposed = primary.frame.offsetBy(dx: offset.width, dy: offset.height)
            let reach = Grid.reach / camera.scale
            let neighbors = index.ids(in: proposed.insetBy(dx: -reach, dy: -reach))
                .filter { m.origins[$0] == nil }.compactMap { items[$0]?.bounds }
            let a = Grid.align(proposed, to: neighbors, tolerance: Grid.tolerance / camera.scale, reach: reach)
            offset.width += a.offset.width
            offset.height += a.offset.height
            lines = a.guides.map { Grid.Guide(from: screenPoint($0.from), to: screenPoint($0.to), side: $0.side) }
        }
        overlay.setGuides(lines)
        // Lifted cards go to the top of the stack, keeping their order relative to each other
        let order = m.origins.values.sorted { $0.z < $1.z }.map(\.id!)
        return m.origins.mapValues { o in
            var moved = o
            moved.frame = o.frame.offsetBy(dx: offset.width, dy: offset.height)
            moved.z = m.top + 1 + Double(order.firstIndex(of: o.id!)!)
            return moved
        }
    }

    // MARK: Mouse up

    public override func mouseUp(with event: NSEvent) {
        switch gesture {
        case .move(let m) where !m.current.isEmpty:
            overlay.setGuides([])
            commit(Array(snapped(m).values), as: String(localized: "移动"))
            gesture = .none
            delegate?.canvasStateChanged(self)
        case .move(let m):
            // Press and release without dragging: opens in the library and while gathering, or when clicking the already selected card on a board
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

    /// On release, in any direction with no neighbor nearby to align to, snap to the grid in that direction (by the top-left corner of the card under the pointer)
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

    /// Updated placements: update layers and index, write to the library, record an undo step. With one card only that row is written; unchanged ones aren't written
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
        // Cards may have moved into or out of view: re-pick which cards get layers
        invalidateRegion()
        let store = store
        Task {
            do { try await store.update(changed); delegate?.canvasDidEdit(self, error: nil) } catch { delegate?.canvasDidEdit(self, error: error) }
        }
    }

    // MARK: Tidy

    /// Arrange the selected cards (the whole board if none selected) into neat rows, with rotation reset. Roughly keeps the original left-to-right, top-to-bottom order
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

    /// Animation for cards changing position: uses the `Motion.place` spring from the design values
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

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: spaceHeld = true                       // Space: hold and drag on empty space to pan
        case 51, 117:                                     // Delete (not while gathering: what's in front of you is a temporary arrangement)
            if !selection.isEmpty, gathering == nil { delegate?.canvas(self, delete: selectedItems) }
        case 36 where cropper != nil: endCrop(commit: true)   // Return: finish cropping
        default: super.keyDown(with: event)
        }
    }

    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) }
    }

    @objc public override func selectAll(_ sender: Any?) { selectAll() }

    /// Deselect (Esc, ✕ on the action bar). Selections in the library are always deliberate, so they take an Esc step; on a board a click selects a single card,
    /// which doesn't take a step, so going back doesn't need an extra press each time; only multiple cards from marquee or ⌘-click do. While gathering, Esc first exits gathering
    public func deselect() -> Bool {
        guard !selection.isEmpty, gathering == nil, browses || selection.count > 1 else { return false }
        selection = []
        return true
    }

    /// ⌘C: puts the selected cards on the clipboard, so ⌘V on another board places a copy. Not recorded while gathering, since what's in front of you is a temporary arrangement
    @objc public func copy(_ sender: Any?) {
        guard gathering == nil else { return }
        delegate?.canvas(self, copy: selectedItems)
    }

    /// ⌘V: files, images, URLs, and text on the clipboard are collected into the current view; cards recorded by ⌘C get a copy placed here
    @objc public func paste(_ sender: Any?) {
        _ = delegate?.canvas(self, accept: .general, at: visibleCenter)
    }

    // MARK: Right click

    public override func menu(for event: NSEvent) -> NSMenu? {
        if let id = item(at: worldPoint(point(event))), !selection.contains(id) {
            // A click in the library doesn't change the selection: right-clicking an unselected card applies to that card only
            if browses, let item = items[id] { return delegate?.canvasMenu(self, for: [item]) }
            selection = [id]
        }
        return selection.isEmpty ? nil : delegate?.canvasMenu(self, for: selectedItems)
    }

    // MARK: Dragging out, dragging in

    /// Dragging off the canvas: system drag and drop carries the IDs of these placements, which the sidebar's boards recognize.
    /// However many are dragged, only one image follows the mouse: the top few visible cards stacked into a small pile with a count; they fly from where they are now (from, missing ones use their placement)
    /// into the pile. On a board this takes the cards away: the ones in place dim, and the canvas reloads after the drop; if the drop doesn't land, they're restored.
    /// Off the canvas it shrinks to a small image so it doesn't cover the board names in the sidebar; dropped onto a board, it shrinks in and disappears
    private func dragOut(_ ids: [Int64], primary: Int64, from: [Int64: Placement], event: NSEvent) {
        guard let window, let placement = from[primary] ?? items[primary]?.placement else { return }
        let payload = (Self.placementsPrefix + ids.map(String.init).joined(separator: ",")) as NSString
        let p = convert(event.locationInWindow, from: nil)
        let c = screenPoint(CGPoint(x: placement.frame.midX, y: placement.frame.midY))
        // The visible ones, with the one being held in front and the rest from top to bottom
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
        // In the library it places a copy: the cards don't leave and don't dim
        if isEditable { dim(Set(ids)) }
        updateOverlay()
        delegate?.canvasStateChanged(self)
        let item = NSDraggingItem(pasteboardWriter: payload)
        let drag = outgoing.drag(at: p)
        item.setDraggingFrame(drag.frame, contents: drag.image)
        beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
        Outgoing.gather(Array(flights), into: window.convertToScreen(convert(drag.top, to: nil)), over: window)
    }

    /// Replace the dimmed cards in place with these
    func dim(_ ids: Set<Int64>) {
        let changed = dimmed.symmetricDifference(ids)
        dimmed = ids
        for id in changed { if let l = live[id] { raise(l, id) } }
    }

    /// The part of the canvas not covered by the sidebar or discussion panel: dragging out of it takes cards elsewhere
    var uncovered: CGRect {
        CGRect(x: viewport.minX, y: 0, width: viewport.width, height: bounds.height)
    }

    /// Placements dragged off the canvas and boards dragged onto it pass their IDs in drag and drop as text with these two prefixes
    public static let placementsPrefix = "piyi-placements:", boardPrefix = "piyi-board:"

    /// Holding ⌥ while dragging to another board places a copy and leaves these here (like Finder). The cursor, whether the cards in place dim, and whether the drop moves or copies all follow it
    public static var keepsHere: Bool { NSEvent.modifierFlags.contains(.option) }

    /// The cursor shows a "+" when placing a copy
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? (Self.keepsHere ? .copy : .move) : []
    }

    public func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let outgoing, let window else { return }
        // Placing a copy: the cards in place don't dim, showing that they stay here
        if isEditable { dim(Self.keepsHere ? [] : outgoing.ids) }
        let drag = outgoing.drag(at: convert(window.convertPoint(fromScreen: screenPoint), from: nil))
        session.enumerateDraggingItems(options: [], for: self, classes: [NSString.self], searchOptions: [:]) { item, _, _ in
            item.setDraggingFrame(drag.frame, contents: drag.image)
        }
    }

    /// Dropped onto a board: the system takes the dragged image right away, so add an identical image here that shrinks and fades out from the mouse, showing that "it went in".
    /// The dimmed cards stay until the canvas reloads and removes or restores them, so they don't light up for a moment before disappearing
    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer {
            outgoing = nil
            updateOverlay()
            delegate?.canvasStateChanged(self)
        }
        guard !operation.isEmpty, let outgoing, let window else { return dim([]) }
        // Placed a copy: the cards in place stay, without waiting for a reload
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

    // MARK: Play button

    /// Where the play buttons on audio cards are drawn (screen points): the hovered card, and the one playing — kept even when not under the pointer, so you can tell which card the sound comes from.
    /// The button sits in the center of the waveform area and scales with the card; not drawn when the card is too small on screen
    func playButtons() -> [(id: Int64, center: CGPoint, size: CGFloat, pause: Bool)] {
        guard cropper == nil, outgoing == nil else { return [] }
        var ids = sounding.map { card in live.keys.filter { items[$0]?.cardID == card } } ?? []
        if let hovered, !ids.contains(hovered) { ids.append(hovered) }
        return ids.compactMap { id -> (id: Int64, center: CGPoint, size: CGFloat, pause: Bool)? in
            guard case .card(let card)? = items[id]?.face, card.kind == .audio, card.original != nil,
                  live[id]?.isHidden == false, let p = placement(id) else { return nil }
            let size: CGFloat = min(p.width * camera.scale * CardType.playMark, Overlay.playKnob.upperBound)
            guard size >= Overlay.playKnob.lowerBound else { return nil }
            // How far the waveform area's center is from the card center; on vertically flipped cards it's on the other side
            let rise = (CardArt.waveform.midY - 0.5) * (p.flipY ? -1 : 1)
            let lift = CGPoint(x: 0, y: rise * p.height).applying(CGAffineTransform(rotationAngle: p.rotation))
            return (id, screenPoint(CGPoint(x: p.frame.midX + lift.x, y: p.frame.midY + lift.y)), size, card.id == sounding)
        }
    }

    /// Which card's play button screen point p falls on
    func playButton(at p: CGPoint) -> Int64? {
        playButtons().first { hypot(p.x - $0.center.x, p.y - $0.center.y) <= $0.size / 2 + Overlay.slop }?.id
    }

    func updatePlayButtons() {
        overlay.setPlayButtons(playButtons().map { ($0.center, $0.size, $0.pause) })
    }

    // MARK: Overlay

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
        // Only one card selected and the mouse hovering over another: the selected one keeps its corner handles too
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

/// The cards being dragged off the canvas (see dragOut). All coordinates are view coordinates (y up)
struct Outgoing {
    /// How far the press point is from the top card's center: while resizing within the canvas the point held stays under the mouse
    let offset: CGPoint
    /// The part of the canvas in the view not covered by the sidebar: shrinking starts only outside it
    let canvas: CGRect
    /// The top card's size on the canvas
    let size: CGSize
    /// Images of the cards in the pile, top one first
    let faces: [CGImage]
    /// Which cards are being dragged
    let ids: Set<Int64>
    var count: Int { ids.count }

    /// How far off the canvas it reaches its smallest, and its longest side at the smallest: slightly taller than a sidebar row, enough to tell which card it is
    static let shrinkDistance: CGFloat = 40, thumb: CGFloat = 44
    /// How many cards a pile shows at most, how many points each is offset to the top right, and the count label's height (points, not scaled down)
    static let layers = 3, step: CGFloat = 4, badge: CGFloat = 18
    /// At most how many cards fly over to stack: once together in one spot you can't tell how many there are, so more would just create more layers and slow down the first drag frame
    static let flights = 12

    /// The image following the mouse at p (frame) and the position of the top card in it (top). Within the canvas it's full size and you hold it where you pressed;
    /// once off the canvas it shrinks to a small image moved to the mouse's lower right, leaving the board name the mouse points at visible
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

    /// A small pile: the ones behind are offset to the top right, with the count label on the pile's top-right corner (no label for a single card)
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

    /// Several cards fly from their own positions on screen to where the target one is, fading as they go, and are caught by the dragged pile on arrival.
    /// They fly with the `Motion.place` spring
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

    /// An image shrinks and fades out somewhere on screen
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

    /// Plays a temporary animation over frame on screen: the drop point is outside the canvas (on the sidebar), out of reach of the canvas's layers,
    /// so it borrows a transparent child window that ignores the mouse, and closes it when the animation is done
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
