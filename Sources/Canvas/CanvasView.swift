import AppKit
import QuartzCore
import Library
import Tokens

/// What the canvas leaves to the shell: detail view, context menu, delete, dropped-in items, entering and leaving cropping (the shell handles Esc in one place)
@MainActor
public protocol CanvasDelegate: AnyObject {
    /// Double-clicked a card or a board entry
    func canvas(_ canvas: CanvasView, open item: BoardItem)
    func canvasMenu(_ canvas: CanvasView, for items: [BoardItem]) -> NSMenu?
    /// Pressed the delete key
    func canvas(_ canvas: CanvasView, delete items: [BoardItem])
    /// Pressed ⌘C
    func canvas(_ canvas: CanvasView, copy items: [BoardItem])
    /// Something dropped in landed at world point point; returns true if accepted
    func canvas(_ canvas: CanvasView, accept pasteboard: NSPasteboard, at point: CGPoint) -> Bool
    /// Clicked the play button on an audio card
    func canvas(_ canvas: CanvasView, play item: BoardItem)
    /// Entering or leaving cropping, selection changes, starting and ending a card drag
    func canvasStateChanged(_ canvas: CanvasView)
    /// Placements changed (drag, resize, rotate, crop, tidy); a non-nil error means it wasn't saved to the library
    func canvasDidEdit(_ canvas: CanvasView, error: Error?)
    /// Undo, redo, or writing a text card changed the library: return once the shell has refreshed (including the canvas reload)
    func canvas(_ canvas: CanvasView, didApply edit: Edit) async
    /// Clicked the source under a gathering result: go to that board and point at this card
    func canvas(_ canvas: CanvasView, reveal card: Int64, on board: Int64)
}

/// What the canvas shows: one board, or one of the card views that aren't boards
public enum CanvasContent: Hashable, Sendable {
    case board(Int64)
    case collection(Store.Collection)
}

/// The canvas: one layer per card, its content drawn as a bitmap handed to the GPU; panning and zooming only change the world layer's transform, never the card contents.
/// Only cards near the view get layers; those outside it are recycled and reused. About 0.1 s after things settle, visible cards are redrawn at the new scale.
public final class CanvasView: NSView {
    public weak var delegate: CanvasDelegate?
    let store: Store
    let world = QuietLayer()
    /// Overlay in screen coordinates: guides, marquee, selection handles, crop frame
    let overlay = Overlay()
    var items: [Int64: BoardItem] = [:]
    var index = SpatialIndex([:])
    var live: [Int64: CardLayer] = [:]
    private var pool: [CardLayer] = []
    /// The area already given layers: the view plus 1/4 screen on each side; recomputed when the view leaves it or zooms in to within a quarter of it
    private var region: CGRect = .null
    var renderScale: CGFloat = 1
    private var shadows = true
    private var settle: DispatchWorkItem?
    /// Re-lay out the library only after the visible area settles (opening and closing the sidebar or discussion panel and resizing the window are a run of continuous changes)
    private var reflow: DispatchWorkItem?
    var gesture = Gesture.none
    var hovered: Int64?
    /// Mouse position in the view; nil when outside the canvas. The rotate knob expands or not by how close it is
    var pointer: CGPoint?
    /// How far a group with differing angles has rotated as a whole: they share no orientation, so the group frame encloses them at this angle, and resets only when the selection changes
    var groupRotation: CGFloat = 0
    var cropper: Cropper?
    /// The cards being dragged off the canvas: how to draw the small pile following the mouse (see dragOut)
    var outgoing: Outgoing?
    /// Cards dimmed in place while being dragged to the sidebar: removed or restored after the drop once the canvas reloads
    var dimmed: Set<Int64> = []
    /// With space held, dragging on empty space pans; otherwise it's a marquee
    var spaceHeld = false
    /// Search and inspiration results gathered up front (see Gather.swift)
    var gathering: Gathering?
    /// Cards that literally match while typing, lit up in place (placement IDs)
    var lit: Set<Int64> = []
    /// A layer of canvas background covering the other cards while gathering or highlighting; gathered and lit cards sit above it
    let veil = QuietLayer()
    var veilZ: Double = 0
    /// Cards in flight: not recycled even outside the view, until they land
    var flying: Set<Int64> = []
    /// Visitors fading out: taken back if a new set requests them during the fade
    var departing: [Int64: Visitor] = [:]
    var landing: UUID?
    /// Data changed elsewhere while gathering: reload after exiting gathering, so the results in front of you aren't scattered
    var needsReload = false
    /// Undo history for each board and each card view (see History.swift)
    var undoHistories: [CanvasContent: UndoManager] = [:]
    /// The text card being written (see NoteEditor.swift)
    var noteEditor: NoteEditor?
    /// The groups of the card views when grouped (see Shelves.swift); which group's title the mouse is over
    var shelves: [Shelf] = []
    var hotShelf: Int?
    /// Where a ⇧ range selection starts: the last ⌘-clicked or ⇧-clicked card, or the first card of the selected group
    var anchor: Int64?
    /// Where you last were on each board and each card view: remembered while the app is open, so you pick up there when you come back
    var cameras: [CanvasContent: Camera] = [:]
    /// Which content the camera is currently on: counts only once read and framed (a content switch still being read doesn't count)
    var shown: CanvasContent?
    /// The most recent full-view framing. While the camera is still there, it reframes whenever the window, sidebar, or discussion panel changes; once you've moved it, your camera is left alone
    var home: Camera?
    /// Where the camera is gliding to (see glide)
    var glide: (link: CADisplayLink, from: Camera, to: Camera, start: CFTimeInterval)?
    /// The row width the library was laid out at (world coordinates): re-lay out when the visible area's width changes
    var shelfWidth: CGFloat = 0
    /// The old scene kept on screen while switching content, and the switch waiting to come up (see Swap.swift)
    var curtain: Curtain?
    var reveal: UUID?
    /// This content switch doesn't fly, only cross-fades (detail view is open: nothing should move under the dimming)
    var still = false
    /// Things to do at the moment the new scene comes up
    var revealed: (@MainActor () -> Void)?

    /// How the card views are grouped; nil means ungrouped, one continuous sheet from newest to oldest. Changing it re-lays out, with cards sliding to new positions
    public var grouping: Grouping? {
        didSet { if case .collection? = content { Task { try? await reload() } } }
    }

    /// The audio card currently playing, told to the canvas by the shell: its play button stays, shown as pause
    public var sounding: Int64? {
        didSet { if sounding != oldValue { updatePlayButtons() } }
    }

    public private(set) var content: CanvasContent?
    public internal(set) var selection: Set<Int64> = [] {
        didSet { if selection != oldValue { selectionChanged(from: oldValue) } }
    }

    /// The viewport. Setting it is "moving the camera"; performance benchmarks drive it from here too
    public var camera = Camera(center: .zero, scale: 1) {
        didSet { if camera != oldValue { apply() } }
    }

    /// Below this zoom, no live shadows: the shadow radius is 3 points, which is under 1 pixel at this zoom
    static let shadowScale: CGFloat = 0.35

    public init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer!.backgroundColor = Palette.canvas.light.cg
        layer!.masksToBounds = true
        // The world layer has zero size with origin at top left; sublayers are placed "y down"
        world.anchorPoint = .zero
        world.bounds = .zero
        world.isGeometryFlipped = true
        layer!.addSublayer(world)
        layer!.addSublayer(overlay)
        veil.frame = CGRect(x: -1e7, y: -1e7, width: 2e7, height: 2e7)
        veil.backgroundColor = Palette.canvas.light.cg
        veil.opacity = 0
        world.addSublayer(veil)
        registerForDraggedTypes([.string, .fileURL, .URL, .tiff, .png])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        // Pinch is received with a gesture recognizer: when the canvas is embedded in a SwiftUI window, pinch events don't reach magnify(with:)
        addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        adoptAppearance()
        // Paper-style card colors follow the appearance: visible cards are redrawn in the new colors, with the background changed before the new images arrive
        for l in live.values { l.repaint(files: store.files) }
        updateShelves()
    }

    /// Whether the window is dark or light: recorded for card drawing, and the canvas and scrim backgrounds switch with it
    private func adoptAppearance() {
        Screen.dark = isDark
        layer!.backgroundColor = Palette.canvas.now.cg
        veil.backgroundColor = layer!.backgroundColor
    }

    // MARK: Content

    /// Switch to other content: read all placements in the background and point the camera at all cards; the old scene stays until the new one is drawn (see Swap.swift)
    /// still: no flying, cross-fade only; revealed: called at the moment the new scene comes up, so things outside can switch along with it
    public func show(_ content: CanvasContent, still: Bool = false, revealed: (@MainActor () -> Void)? = nil) async throws {
        // Cancel the previous one still waiting to be drawn: when it comes up it mustn't claim this one's callback
        reveal = nil
        (self.still, self.revealed) = (still, revealed)
        finishEditing()
        stopGlide()
        // Only record if the camera was moved; if it's still at the full view, don't, and reframe next time for the window at that time
        if let shown, shown != content { cameras[shown] = camera == home ? nil : camera }
        shown = nil
        self.content = content
        endCrop(commit: false)
        let (loaded, shelves) = try await load(content)
        guard self.content == content else { return }
        self.shelves = shelves
        hotShelf = nil
        anchor = nil
        lowerCurtain()
        gathering = nil
        lit = []
        flying = []
        departing = [:]
        needsReload = false
        veil.removeAllAnimations()
        veil.opacity = 0
        overlay.setTags([])
        selection = []
        hovered = nil
        items = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        index = SpatialIndex(items.mapValues(\.bounds))
        region = .null
        needsFit = true
        fitIfReady()
        revealWhenPainted()
        delegate?.canvasStateChanged(self)
    }

    /// Re-read the same content (placements changed or cards deleted elsewhere) without moving the camera; changed cards are redrawn.
    /// The card views are laid out: when cards are deleted or grouping changes, the cards in front of you slide to new positions to fill in
    public func reload() async throws {
        guard let content else { return }
        // No reload while gathering: the results in front of you are a temporary arrangement that a reload would scatter
        guard gathering == nil else { needsReload = true; return }
        let (loaded, shelves) = try await load(content)
        guard self.content == content, gathering == nil else { return }
        let fresh = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        for id in items.keys where fresh[id] == nil {
            index.remove(id)
            if let l = live.removeValue(forKey: id) { recycle(l) }
        }
        // Dimmed while dragged to the sidebar: the ones taken away were already removed above; restore the rest
        dim([])
        let glides = if case .collection = content { true } else { false }
        let seen = camera.visibleRect(in: bounds.size), wasLive = Set(live.keys)
        var from: [Int64: Placement] = [:]
        for (id, item) in fresh where items[id] != item {
            index.update(id, item.bounds)
            // Visible cards (in view before or now) slide over; the rest switch directly
            if glides, let old = items[id], old.placement.frame != item.placement.frame,
               live[id] != nil || item.bounds.intersects(seen) {
                from[id] = old.placement
            } else if let l = live[id] {
                refresh(l, with: item)
            }
        }
        items = fresh
        self.shelves = shelves
        selection = selection.filter { fresh[$0] != nil }
        if !from.isEmpty { stage(from: from, fadeIn: [], wasLive: wasLive) }
        // Newly collected cards go first and the stacking order of the rest shifts back by one: the scrim is recomputed with it, so the oldest card is still de-emphasized when selected
        updateVeil()
        region = .null
        apply()
        delegate?.canvasStateChanged(self)
    }

    private func load(_ content: CanvasContent) async throws -> ([BoardItem], [Shelf]) {
        switch content {
        case .board(let id):
            return (try await store.items(on: id), [])
        case .collection(let collection):
            let files = store.files, grouping = grouping, width = Self.shelfWidth(for: viewport.width)
            let cards = try await store.cards(in: collection)
            shelfWidth = width
            return await Task.detached(priority: .userInitiated) { Self.lay(cards, grouping: grouping, files: files, width: width) }.value
        }
    }

    /// Whether it can be arranged: only placements on a board can change; the card views and gathering results are temporary layouts
    public var isEditable: Bool { if case .board = content { gathering == nil } else { false } }

    public var board: Int64? { if case .board(let id) = content { id } else { nil } }

    /// Dragging cards off the canvas
    public var isDraggingOut: Bool { outgoing != nil }

    /// Dragging cards: moving them on the board, or already dragged off the canvas
    public var isMovingCards: Bool {
        if case .move(let m) = gesture, !m.current.isEmpty { return true }
        return isDraggingOut
    }

    /// Done reading, and there are no cards at all
    public var isEmpty: Bool { items.isEmpty && !needsFit }

    /// The card reached with the left/right keys in detail view: in laid-out order in the library, in result order while gathering; nil at the end.
    /// Cards on a board are placed freely, so there's no previous or next
    public func neighbor(of card: Int64, by step: Int) -> Int64? {
        let order: [Int64]
        if let gathering { order = gathering.members.compactMap { items[$0]?.cardID } }
        else if browses { order = items.values.sorted { $0.placement.z < $1.placement.z }.compactMap(\.cardID) }
        else { return nil }
        guard let i = order.firstIndex(of: card), order.indices.contains(i + step) else { return nil }
        return order[i + step]
    }

    public var selectedItems: [BoardItem] { selection.compactMap { items[$0] }.sorted { $0.placement.z < $1.placement.z } }

    public func selectAll() { selection = Set(items.keys) }

    /// Get by placement ID (used when dragging to the sidebar)
    public func items(_ ids: [Int64]) -> [BoardItem] { ids.compactMap { items[$0] } }

    /// Bounding box of all cards
    public var contentBounds: CGRect { index.bounds }
    /// The camera is still at the full view and hasn't been moved
    public var isAtPanorama: Bool { glide == nil && home.map { camera == $0 } == true }

    /// Placements that intersect a region
    public func placements(in rect: CGRect) -> Set<Int64> { index.ids(in: rect) }

    // MARK: Camera

    /// When the view has no size yet (just put in a window), remember it and frame on the first layout
    private var needsFit = false

    private func fitIfReady() {
        guard needsFit, bounds.width > 0, bounds.height > 0 else { return }
        needsFit = false
        shown = content
        // Visited and the camera moved during this session: return to where you were last
        if let content, let seen = cameras[content] {
            home = nil
            if live.isEmpty { renderScale = seen.scale }
            if camera == seen { apply() } else { camera = seen }
        } else {
            fitAll()
        }
    }

    /// How wide the sidebar, toolbar, and discussion panel cover each side of the canvas, told to the canvas by the shell
    public var covered = NSEdgeInsets() {
        didSet { if !NSEdgeInsetsEqual(covered, oldValue) { needsLayout = true } }
    }

    /// The visible area (view points, y down): the canvas extends under the sidebar, toolbar, and discussion panel, with the search bar floating at the bottom; this is the part they don't cover.
    /// Everywhere cards are placed on screen uses it: full-view framing, library row width, gathering, and detecting drags off the canvas
    var viewport: CGRect {
        let s = covered, bar = CGFloat(Chrome.inset + Chrome.searchHeight)
        return CGRect(x: s.left, y: s.top, width: max(bounds.width - s.left - s.right, 1), height: max(bounds.height - s.top - s.bottom - bar, 1))
    }

    /// Put a region of the world in the center of the visible area, with a little margin around it
    func framing(_ rect: CGRect) -> Camera {
        centering(rect.isNull ? .zero : rect, scale: Camera.fitting(rect, in: viewport.size).scale)
    }

    /// At a given zoom, put a region's center in the center of the visible area
    func centering(_ rect: CGRect, scale: CGFloat) -> Camera {
        let viewport = viewport
        return Camera(center: CGPoint(x: rect.midX - (viewport.midX - bounds.width / 2) / scale, y: rect.midY - (viewport.midY - bounds.height / 2) / scale), scale: scale)
    }

    /// Full view: see the whole current board. The card views read like a long page: when it doesn't all fit, frame by row width, start from the top, and scroll down;
    /// the first row sits 60 points below the toolbar, leaving room for the first group's title
    private var panorama: Camera {
        var fit = framing(index.bounds)
        if case .collection? = content, !index.bounds.isNull {
            let b = index.bounds, viewport = viewport, wide = framing(CGRect(x: b.minX, y: b.minY, width: b.width, height: 1))
            if wide.scale > fit.scale {
                fit = Camera(center: CGPoint(x: wide.center.x, y: b.minY + (bounds.height / 2 - viewport.minY - 60) / wide.scale), scale: wide.scale)
            }
        }
        return fit
    }

    /// Back to full view. ⌘0 glides there (animated); just opened or a window change places it directly
    public func fitAll(animated: Bool = false) {
        let fit = panorama
        home = fit
        if animated, !live.isEmpty { glide(to: fit); return }
        stopGlide()
        if live.isEmpty { renderScale = fit.scale }
        if camera == fit { apply() } else { camera = fit }
    }

    /// Select the cards just placed; if some aren't in front of you, glide the camera to them
    public func reveal(_ ids: Set<Int64>) {
        selection = ids.intersection(items.keys)
        let placed = selectedItems.reduce(CGRect.null) { $0.union($1.bounds) }
        let seen = CGRect(origin: worldPoint(viewport.origin), size: CGSize(width: viewport.width / camera.scale, height: viewport.height / camera.scale))
        guard !placed.isNull, !seen.contains(placed) else { return }
        glide(to: centering(placed, scale: camera.scale))
    }

    /// Glide the camera to a card
    public func focus(_ id: Int64) {
        guard let item = items[id] else { return }
        selection = [id]
        glide(to: centering(item.bounds, scale: max(camera.scale, 0.6)))
    }

    /// The camera glides elsewhere using the `Motion.place` duration, fast then slow; the zoom changes proportionally so zooming looks steady.
    /// It stops as soon as you move the camera on the way, deferring to you
    func glide(to target: Camera) {
        stopGlide()
        guard camera != target, window != nil else { camera = target; return }
        let link = displayLink(target: self, selector: #selector(glideStep(_:)))
        glide = (link, camera, target, CACurrentMediaTime())
        link.add(to: .main, forMode: .common)
    }

    @objc private func glideStep(_ link: CADisplayLink) {
        guard let g = glide else { return }
        let t = min(1, (CACurrentMediaTime() - g.start) / Motion.place.response), k = CGFloat(1 - pow(1 - t, 3))
        let scale = g.from.scale * pow(g.to.scale / g.from.scale, k)
        // The last frame lands exactly on the destination: the computed value might be off by one least unit, and then "still at the full view" wouldn't recognize it
        camera = t >= 1 ? g.to : Camera(center: CGPoint(x: g.from.center.x + (g.to.center.x - g.from.center.x) * k, y: g.from.center.y + (g.to.center.y - g.from.center.y) * k), scale: scale)
        if t >= 1 { stopGlide() }
    }

    func stopGlide() {
        glide?.link.invalidate()
        glide = nil
    }

    public override func layout() {
        super.layout()
        overlay.frame = bounds
        if needsFit { fitIfReady(); return }
        // The library needs a new row width: opening or closing the sidebar is dozens of frames of continuous change, and re-laying out every frame would make cards jump repeatedly and flicker.
        // During the change the cards stay put; once settled they're laid out once and slide over
        if needsReflow { scheduleReflow(); apply(); return }
        // The camera is still at the full view: reframe whenever the window, sidebar, or discussion panel changes
        if glide == nil, let home, camera == home { fitAll() } else { apply() }
    }

    /// How wide a library row is (world coordinates): keeps a row of cards about 120 points tall on screen, so a wide window fits more cards per row and a narrow one fewer, instead of shrinking the whole page
    static func shelfWidth(for width: CGFloat) -> CGFloat {
        let scale = 120 / CGFloat(Space.rowHeight)
        return min(max(Grid.snap((width - 80) / scale), Grid.unit * 40), Layout.shelfWidth)
    }

    /// The visible area's width changed (resizing the window, opening or closing the sidebar or discussion panel): the library needs a new row width
    private var needsReflow: Bool {
        guard case .collection? = content, gathering == nil, shelfWidth > 0 else { return false }
        return Self.shelfWidth(for: viewport.width) != shelfWidth
    }

    private func scheduleReflow() {
        reflow?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reflowNow() }
        reflow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Re-lay out the library at the new width: cards slide to new positions while the camera glides back to the page's width
    private func reflowNow() {
        reflow = nil
        guard needsReflow else { return }
        shelfWidth = Self.shelfWidth(for: viewport.width)
        // However far down the page you were reading, stay there after the re-layout
        let before = index.bounds, top = camera.world(at: CGPoint(x: 0, y: viewport.minY), in: bounds.size).y
        let read = before.isNull || before.height == 0 ? 0 : max(0, (top - before.minY) / before.height)
        let content = content
        Task {
            try? await reload()
            // Content switched or gathering started while waiting: this re-layout is cancelled
            guard self.content == content, gathering == nil else { return }
            let fit = panorama
            home = fit
            glide(to: Camera(center: CGPoint(x: fit.center.x, y: fit.center.y + read * index.bounds.height), scale: fit.scale))
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        adoptAppearance()
        Screen.scale = window.backingScaleFactor
        if let space = window.screen?.colorSpace?.cgColorSpace { Screen.colorSpace = space }
    }

    func apply() {
        if live.isEmpty { renderScale = camera.scale }
        let size = bounds.size
        world.position = CGPoint(x: size.width / 2 - camera.center.x * camera.scale, y: size.height - (size.height / 2 - camera.center.y * camera.scale))
        world.setAffineTransform(CGAffineTransform(scaleX: camera.scale, y: camera.scale))
        let wantShadows = camera.scale >= Self.shadowScale
        if wantShadows != shadows {
            shadows = wantShadows
            for l in live.values { l.setShadow(shadows) }
        }
        let visible = camera.visibleRect(in: size)
        if !region.contains(visible) || visible.width < region.width / 4 {
            region = visible.insetBy(dx: -visible.width / 4, dy: -visible.height / 4)
            reconcile(index.ids(in: region))
        }
        updateOverlay()
        layoutEditor()
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sharpen() }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Placements changed: the next apply re-picks the cards near the view
    func invalidateRegion() {
        region = .null
        apply()
    }

    /// Those outside the view are recycled into the pool (cancelling their unfinished loads); newcomers are taken from the pool
    private func reconcile(_ ids: Set<Int64>) {
        let keep = gesture.moving.union(flying)
        for (id, l) in live where !ids.contains(id) && !keep.contains(id) {
            recycle(l)
            live[id] = nil
        }
        for id in ids where live[id] == nil { adopt(id) }
    }

    /// Give a card a layer (from the pool) and draw it at the current scale
    @discardableResult
    func adopt(_ id: Int64) -> CardLayer? {
        guard let item = items[id] else { return nil }
        let l = pool.popLast() ?? CardLayer()
        l.bind(item)
        l.setShadow(shadows)
        // The one being written is replaced by the text box
        l.isHidden = noteEditor?.placement == id
        raise(l, id)
        world.addSublayer(l)
        live[id] = l
        l.render(at: renderScale, files: store.files)
        return l
    }

    func recycle(_ l: CardLayer) {
        l.unbind()
        l.removeFromSuperlayer()
        pool.append(l)
    }

    /// Placements changed: if only position or angle changed, just move the layer; redraw only if size, crop, content, or the newly-placed mark changed.
    /// If size or crop changed the old image no longer fits, so clear and redraw; if only content or the mark changed, keep the old image and transition once the new one is drawn
    func refresh(_ l: CardLayer, with item: BoardItem) {
        let old = l.item
        l.place(item.placement)
        raise(l, item.id)
        let reshaped = old?.placement.frame.size != item.placement.frame.size || old?.placement.crop != item.placement.crop
        guard reshaped || old?.face != item.face || old?.placement.unseen != item.placement.unseen else { return }
        if reshaped { l.bind(item) } else { l.revise(item) }
        l.render(at: renderScale, files: store.files)
    }

    /// After things settle: cards whose scale changed enough to need a different tier are redrawn at the new scale; the old image shows until the new one arrives
    private func sharpen() {
        renderScale = camera.scale
        for l in live.values {
            guard let item = l.item else { continue }
            if Painter.isStale(item, renderedAt: l.scale, for: renderScale) { l.render(at: renderScale, files: store.files) }
        }
    }

    private func selectionChanged(from old: Set<Int64>) {
        groupRotation = 0
        updateVeil()
        updateOverlay()
        delegate?.canvasStateChanged(self)
    }

    /// The hovered card is lifted (stacking order unchanged); animated images start moving, local videos start a muted preview
    func setHovered(_ id: Int64?) {
        guard id != hovered else { return }
        let old = hovered
        hovered = id
        if let old, let l = live[old] {
            l.hover(false, files: store.files)
            l.setLifted(false)
        }
        // Don't lift while dragging, resizing, or rotating, so the card under the pointer doesn't suddenly grow
        if let id, let l = live[id] {
            l.hover(true, files: store.files)
            if case .none = gesture { l.setLifted(true) }
        }
    }

    /// Mid drag, resize, or rotate: layers switch to the new placement and the stacking order (above the scrim) is recomputed
    func display(_ placements: [Int64: Placement]) {
        for (id, p) in placements {
            guard let l = live[id] else { continue }
            l.place(p)
            raise(l, id)
        }
    }
}

extension Placement {
    /// The bounding box after rotation
    var bounds: CGRect {
        guard rotation != 0 else { return frame }
        let t = CGAffineTransform(translationX: frame.midX, y: frame.midY).rotated(by: rotation).translatedBy(x: -frame.midX, y: -frame.midY)
        return frame.applying(t)
    }
}

extension BoardItem {
    /// Long image: the cover only shows the top part
    var isLong: Bool { if case .card(let card) = face { card.form == .long } else { false } }

    /// The bounding box after rotation, used to find cards in view
    var bounds: CGRect { placement.bounds }

    /// Whether a world point falls on this card (accounting for rotation)
    func contains(_ p: CGPoint) -> Bool {
        let f = placement.frame
        let local = CGPoint(x: p.x - f.midX, y: p.y - f.midY).applying(CGAffineTransform(rotationAngle: -placement.rotation))
        return abs(local.x) <= f.width / 2 && abs(local.y) <= f.height / 2
    }
}
