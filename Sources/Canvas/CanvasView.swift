import AppKit
import QuartzCore
import Library
import Tokens

/// 画布交给外壳决定的事：放大查看、右键菜单、删除、拖进来的东西、进出裁剪（Esc 由外壳统一管）
@MainActor
public protocol CanvasDelegate: AnyObject {
    /// 双击一张卡或一个画板入口
    func canvas(_ canvas: CanvasView, open item: BoardItem)
    func canvasMenu(_ canvas: CanvasView, for items: [BoardItem]) -> NSMenu?
    /// 按了删除键
    func canvas(_ canvas: CanvasView, delete items: [BoardItem])
    /// 按了 ⌘C
    func canvas(_ canvas: CanvasView, copy items: [BoardItem])
    /// 拖进来的东西落在世界坐标 point；收下了返回 true
    func canvas(_ canvas: CanvasView, accept pasteboard: NSPasteboard, at point: CGPoint) -> Bool
    /// 点了音频卡上的播放钮
    func canvas(_ canvas: CanvasView, play item: BoardItem)
    /// 进出裁剪、选中变化、开始和结束拖卡
    func canvasStateChanged(_ canvas: CanvasView)
    /// 摆放改了（拖动、缩放、旋转、裁剪、整理）；error 不为空表示没存进资料库
    func canvasDidEdit(_ canvas: CanvasView, error: Error?)
    /// 撤销、重做、写文字卡改了资料库：外壳刷新（含画布重读）完再返回
    func canvas(_ canvas: CanvasView, didApply edit: Edit) async
    /// 点了聚拢结果下面的出处：去那个画板，对准这张卡
    func canvas(_ canvas: CanvasView, reveal card: Int64, on board: Int64)
}

/// 画布上显示的是什么：一个画板，或者几种不属于画板的卡片视图
public enum CanvasContent: Hashable, Sendable {
    case board(Int64)
    case collection(Store.Collection)
}

/// 画布：每张卡一个图层，内容画成位图交给显卡；平移缩放只改世界图层的变换，不碰卡片内容。
/// 只放视野附近的卡，视野外的回收复用；停手约 0.1 秒后按新倍率重画可见的卡。
public final class CanvasView: NSView {
    public weak var delegate: CanvasDelegate?
    let store: Store
    let world = QuietLayer()
    /// 屏幕坐标的浮层：对齐线、框选框、选中的控制点、裁剪框
    let overlay = Overlay()
    var items: [Int64: BoardItem] = [:]
    var index = SpatialIndex([:])
    var live: [Int64: CardLayer] = [:]
    private var pool: [CardLayer] = []
    /// 已经放进图层的范围：视野四周各多留 1/4 屏，视野走出这块、或放大到它的四分之一以内才重算
    private var region: CGRect = .null
    var renderScale: CGFloat = 1
    private var shadows = true
    private var settle: DispatchWorkItem?
    /// 可见区域停稳后再重排资料库（侧边栏、讨论栏开合和拉窗口是一串连续的变化）
    private var reflow: DispatchWorkItem?
    var gesture = Gesture.none
    var hovered: Int64?
    /// 鼠标在视图里的位置；移出画布时为 nil。旋转钮按它离得多近决定展不展开
    var pointer: CGPoint?
    /// 角度各不相同的一组整组转过多少：它们没有共同的朝向，组框按这个角度框住它们，换了选中才回正
    var groupRotation: CGFloat = 0
    var cropper: Cropper?
    /// 正拖出画布的那几张：跟着鼠标的那一小摞怎么画（见 dragOut）
    var outgoing: Outgoing?
    /// 拖去侧边栏时原位上变淡的卡：落下后等画布重读再拿走或复原
    var dimmed: Set<Int64> = []
    /// 按住空格时拖空白处是平移，否则是框选
    var spaceHeld = false
    /// 搜索、灵感的结果聚拢在眼前（见 Gather.swift）
    var gathering: Gathering?
    /// 打字时字面命中、原地亮起的卡（摆放编号）
    var lit: Set<Int64> = []
    /// 聚拢、亮起时盖在其余卡片上的一层画布底色；聚拢的、亮起的卡排在它上面
    let veil = QuietLayer()
    var veilZ: Double = 0
    /// 正在飞的卡：视野外也不回收，飞完再说
    var flying: Set<Int64> = []
    /// 正在淡出的访客：淡出期间又被新的一组要回去时取回
    var departing: [Int64: Visitor] = [:]
    var landing: UUID?
    /// 聚拢时别处改了数据：退出聚拢后再重读，免得把眼前的结果冲散
    var needsReload = false
    /// 每个画板、每种卡片视图各自的撤销记录（见 History.swift）
    var undoHistories: [CanvasContent: UndoManager] = [:]
    /// 正在写的文字卡（见 NoteEditor.swift）
    var noteEditor: NoteEditor?
    /// 几种卡片视图分组时的各组（见 Shelves.swift）；鼠标停在哪一组的标题上
    var shelves: [Shelf] = []
    var hotShelf: Int?
    /// ⇧ 选一段从哪张算起：上次 ⌘ 点、⇧ 点的那张，或选中的那一组的第一张
    var anchor: Int64?
    /// 每个画板、每种卡片视图上次看到哪：这次打开期间记着，再回来接着看
    var cameras: [CanvasContent: Camera] = [:]
    /// 镜头眼下对着的是哪块内容：读完、取过景才算（换内容时还在读的那一段不算）
    var shown: CanvasContent?
    /// 最近一次取的全景。镜头还停在它上面时，窗口、侧边栏、讨论栏一变就跟着重新取景；挪开过就不动你的镜头
    var home: Camera?
    /// 镜头正在滑向哪（见 glide）
    var glide: (link: CADisplayLink, from: Camera, to: Camera, start: CFTimeInterval)?
    /// 资料库是按多宽排的行（世界坐标）：可见区域的宽度变了就重排
    var shelfWidth: CGFloat = 0
    /// 换内容时留在屏幕上的旧画面，和正在等着换上来的那一次（见 Swap.swift）
    var curtain: Curtain?
    var reveal: UUID?
    /// 这次换内容不飞，只交叉淡化（放大查看开着：压暗的底下不该有东西在动）
    var still = false
    /// 新画面换上来的那一刻要一起做的事
    var revealed: (@MainActor () -> Void)?

    /// 几种卡片视图按什么分组；nil 是不分组，从新到旧排成一整片。换了就重排，卡片滑到新位置
    public var grouping: Grouping? {
        didSet { if case .collection? = content { Task { try? await reload() } } }
    }

    /// 正在出声的那张音频卡，由外壳告诉画布：它的播放钮一直留着，显示成暂停
    public var sounding: Int64? {
        didSet { if sounding != oldValue { updatePlayButtons() } }
    }

    public private(set) var content: CanvasContent?
    public internal(set) var selection: Set<Int64> = [] {
        didSet { if selection != oldValue { selectionChanged(from: oldValue) } }
    }

    /// 视口。设它就是「移动镜头」，性能基准也从这里驱动
    public var camera = Camera(center: .zero, scale: 1) {
        didSet { if camera != oldValue { apply() } }
    }

    /// 缩放倍率低于这个值时不画实时阴影：阴影半径 3 点，缩到这里已不到 1 个像素
    static let shadowScale: CGFloat = 0.35

    public init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer!.backgroundColor = Palette.canvas.light.cg
        layer!.masksToBounds = true
        // 世界图层零尺寸、原点在左上，子图层按「y 向下」摆放
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
        // 双指捏合用手势识别器收：画布嵌在 SwiftUI 窗口里时，捏合事件到不了 magnify(with:)
        addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        adoptAppearance()
        // 纸样卡片的颜色跟着外观走：眼前的卡按新颜色重画，新图到之前先换底色
        for l in live.values { l.repaint(files: store.files) }
        updateShelves()
    }

    /// 窗口是深是浅：记下来给画卡片的用，画布和幕的底色跟着换
    private func adoptAppearance() {
        Screen.dark = isDark
        layer!.backgroundColor = Palette.canvas.now.cg
        veil.backgroundColor = layer!.backgroundColor
    }

    // MARK: 内容

    /// 换成另一块内容：后台读出全部摆放，镜头对准全部卡片；旧画面留到新画面画好再换（见 Swap.swift）
    /// still：不飞，只交叉淡化；revealed：新画面换上来的那一刻叫一声，外面的东西好跟着一起换
    public func show(_ content: CanvasContent, still: Bool = false, revealed: (@MainActor () -> Void)? = nil) async throws {
        // 上一次还在等画好的作废：它换上来时不能把这一次的回调领走
        reveal = nil
        (self.still, self.revealed) = (still, revealed)
        finishEditing()
        stopGlide()
        // 镜头挪开过才记；还停在全景上的不记，下次来按那时的窗口重新取景
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

    /// 同一块内容重新读一遍（别处改了摆放、删了卡），镜头不动；变了的卡重画。
    /// 几种卡片视图是排出来的：删了卡、换了分组，眼前的卡滑到新位置补上
    public func reload() async throws {
        guard let content else { return }
        // 聚拢时不重读：眼前的结果是临时摆法，重读会把它冲散
        guard gathering == nil else { needsReload = true; return }
        let (loaded, shelves) = try await load(content)
        guard self.content == content, gathering == nil else { return }
        let fresh = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        for id in items.keys where fresh[id] == nil {
            index.remove(id)
            if let l = live.removeValue(forKey: id) { recycle(l) }
        }
        // 拖去侧边栏时变淡的：拿走了的上面已经收掉，留下的复原
        dim([])
        let glides = if case .collection = content { true } else { false }
        let seen = camera.visibleRect(in: bounds.size), wasLive = Set(live.keys)
        var from: [Int64: Placement] = [:]
        for (id, item) in fresh where items[id] != item {
            index.update(id, item.bounds)
            // 看得见的卡（原来或现在在视野里）滑过去，其余直接换
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
        // 新收进的卡排在最前，其余的叠放次序都往后挪了一位：幕跟着重算，选中时最老的那张也照样弱化
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

    /// 能不能摆：只有画板里的摆放能改，几种卡片视图和聚拢的结果是临时排出来的
    public var isEditable: Bool { if case .board = content { gathering == nil } else { false } }

    public var board: Int64? { if case .board(let id) = content { id } else { nil } }

    /// 正把卡拖出画布
    public var isDraggingOut: Bool { outgoing != nil }

    /// 正拖着卡：在画板里挪，或者已经拖出画布
    public var isMovingCards: Bool {
        if case .move(let m) = gesture, !m.current.isEmpty { return true }
        return isDraggingOut
    }

    /// 读完了、一张卡也没有
    public var isEmpty: Bool { items.isEmpty && !needsFit }

    /// 放大查看里按左右键换到的那张卡：资料库按排出来的顺序，聚拢时按结果的顺序，到头返回 nil。
    /// 画板里的卡是随手摆的，没有上一张、下一张
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

    /// 按摆放编号取（拖到侧边栏时用）
    public func items(_ ids: [Int64]) -> [BoardItem] { ids.compactMap { items[$0] } }

    /// 全部卡片的外框
    public var contentBounds: CGRect { index.bounds }
    /// 镜头还停在全景上，没被挪开过
    public var isAtPanorama: Bool { glide == nil && home.map { camera == $0 } == true }

    /// 和一块区域相交的摆放
    public func placements(in rect: CGRect) -> Set<Int64> { index.ids(in: rect) }

    // MARK: 镜头

    /// 视图还没有尺寸时（刚放进窗口）先记着，等第一次布局再取景
    private var needsFit = false

    private func fitIfReady() {
        guard needsFit, bounds.width > 0, bounds.height > 0 else { return }
        needsFit = false
        shown = content
        // 这次打开期间来过、镜头挪开过：回到上次看的位置
        if let content, let seen = cameras[content] {
            home = nil
            if live.isEmpty { renderScale = seen.scale }
            if camera == seen { apply() } else { camera = seen }
        } else {
            fitAll()
        }
    }

    /// 画布四边被侧边栏、工具栏、讨论栏盖住多宽，由外壳告诉画布
    public var covered = NSEdgeInsets() {
        didSet { if !NSEdgeInsetsEqual(covered, oldValue) { needsLayout = true } }
    }

    /// 可见区域（视图里的点，y 向下）：画布铺在侧边栏、工具栏、讨论栏底下，底部还浮着搜索栏，这一块是没被它们盖住的。
    /// 卡片摆在屏幕哪里都按它算：全景取景、资料库排多宽、聚拢、拖出画布的判定
    var viewport: CGRect {
        let s = covered, bar = CGFloat(Chrome.inset + Chrome.searchHeight)
        return CGRect(x: s.left, y: s.top, width: max(bounds.width - s.left - s.right, 1), height: max(bounds.height - s.top - s.bottom - bar, 1))
    }

    /// 把世界里的一块区域放进可见区域正中，四周留一点边
    func framing(_ rect: CGRect) -> Camera {
        centering(rect.isNull ? .zero : rect, scale: Camera.fitting(rect, in: viewport.size).scale)
    }

    /// 按给定倍率，把一块区域的中心放在可见区域正中
    func centering(_ rect: CGRect, scale: CGFloat) -> Camera {
        let viewport = viewport
        return Camera(center: CGPoint(x: rect.midX - (viewport.midX - bounds.width / 2) / scale, y: rect.midY - (viewport.midY - bounds.height / 2) / scale), scale: scale)
    }

    /// 全景：看全当前画板。几种卡片视图像一页长文：整个放不下时按行宽取景，从最上面看起，往下滚；
    /// 第一行顶在工具栏下方 60 点，留出第一组的标题
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

    /// 回到全景。你按 ⌘0 是滑过去（animated），刚打开、窗口变了是直接摆好
    public func fitAll(animated: Bool = false) {
        let fit = panorama
        home = fit
        if animated, !live.isEmpty { glide(to: fit); return }
        stopGlide()
        if live.isEmpty { renderScale = fit.scale }
        if camera == fit { apply() } else { camera = fit }
    }

    /// 选中刚放进来的几张；有不在眼前的，镜头滑过去对准它们
    public func reveal(_ ids: Set<Int64>) {
        selection = ids.intersection(items.keys)
        let placed = selectedItems.reduce(CGRect.null) { $0.union($1.bounds) }
        let seen = CGRect(origin: worldPoint(viewport.origin), size: CGSize(width: viewport.width / camera.scale, height: viewport.height / camera.scale))
        guard !placed.isNull, !seen.contains(placed) else { return }
        glide(to: centering(placed, scale: camera.scale))
    }

    /// 镜头滑过去对准一张卡
    public func focus(_ id: Int64) {
        guard let item = items[id] else { return }
        selection = [id]
        glide(to: centering(item.bounds, scale: max(camera.scale, 0.6)))
    }

    /// 镜头滑到另一处，用「换位置」的时长，先快后慢；倍率按比例变，缩放的速度看起来才均匀。
    /// 途中你一动镜头就停下，听你的
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
        // 最后一帧直接落在终点上：算出来的值可能差一个最小单位，「还停在全景上」就认不出了
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
        // 资料库要换行宽：开合侧边栏是几十帧连续的变化，每帧都重排会叠着起跳、来回闪。
        // 变化途中卡片原地不动，停稳后一次排好、滑过去
        if needsReflow { scheduleReflow(); apply(); return }
        // 镜头还停在全景上：窗口、侧边栏、讨论栏变了就跟着重新取景
        if glide == nil, let home, camera == home { fitAll() } else { apply() }
    }

    /// 资料库一行排多宽（世界坐标）：让一行卡在屏幕上约 120 点高，窗口宽就多排几张，窄就少排几张，不是整页缩小
    static func shelfWidth(for width: CGFloat) -> CGFloat {
        let scale = 120 / CGFloat(Space.rowHeight)
        return min(max(Grid.snap((width - 80) / scale), Grid.unit * 40), Layout.shelfWidth)
    }

    /// 可见区域的宽度变了（拉窗口、开合侧边栏和讨论栏），资料库该换行宽了
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

    /// 资料库按新宽度重排：卡片滑到新位置，镜头同时滑回这一页的宽度
    private func reflowNow() {
        reflow = nil
        guard needsReflow else { return }
        shelfWidth = Self.shelfWidth(for: viewport.width)
        // 读到这一页的几分之几，重排后还停在那里
        let before = index.bounds, top = camera.world(at: CGPoint(x: 0, y: viewport.minY), in: bounds.size).y
        let read = before.isNull || before.height == 0 ? 0 : max(0, (top - before.minY) / before.height)
        let content = content
        Task {
            try? await reload()
            // 等的时候换了内容、进了聚拢：这次重排作废
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

    /// 摆放变了：下一次 apply 重新挑视野附近的卡
    func invalidateRegion() {
        region = .null
        apply()
    }

    /// 视野外的回收进池子（取消它还没完成的加载），新进来的从池子取
    private func reconcile(_ ids: Set<Int64>) {
        let keep = gesture.moving.union(flying)
        for (id, l) in live where !ids.contains(id) && !keep.contains(id) {
            recycle(l)
            live[id] = nil
        }
        for id in ids where live[id] == nil { adopt(id) }
    }

    /// 给一张卡放上图层（从池子取），按当前倍率画
    @discardableResult
    func adopt(_ id: Int64) -> CardLayer? {
        guard let item = items[id] else { return nil }
        let l = pool.popLast() ?? CardLayer()
        l.bind(item)
        l.setShadow(shadows)
        // 正在写的那张由文本框代替
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

    /// 摆放变了：位置角度变了只挪图层，尺寸、裁剪、内容、新放进标记变了才重画。
    /// 尺寸、裁剪变了旧图对不上，清掉重画；只是内容或标记变了，留着旧图，新图画好再化过去
    func refresh(_ l: CardLayer, with item: BoardItem) {
        let old = l.item
        l.place(item.placement)
        raise(l, item.id)
        let reshaped = old?.placement.frame.size != item.placement.frame.size || old?.placement.crop != item.placement.crop
        guard reshaped || old?.face != item.face || old?.placement.unseen != item.placement.unseen else { return }
        if reshaped { l.bind(item) } else { l.revise(item) }
        l.render(at: renderScale, files: store.files)
    }

    /// 停手后：倍率变化大到需要换档的卡，按新倍率重画；新图到之前继续显示旧图
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

    /// 悬停的卡拿起来（不改叠放次序）；动图开始动，本机视频开始静音预览
    func setHovered(_ id: Int64?) {
        guard id != hovered else { return }
        let old = hovered
        hovered = id
        if let old, let l = live[old] {
            l.hover(false, files: store.files)
            l.setLifted(false)
        }
        // 正在拖、缩放、旋转时不拿起来，免得手底下的卡突然变大
        if let id, let l = live[id] {
            l.hover(true, files: store.files)
            if case .none = gesture { l.setLifted(true) }
        }
    }

    /// 拖动、缩放、旋转途中：图层换成新摆法，叠放次序（排在幕上面）跟着重算
    func display(_ placements: [Int64: Placement]) {
        for (id, p) in placements {
            guard let l = live[id] else { continue }
            l.place(p)
            raise(l, id)
        }
    }
}

extension Placement {
    /// 转过之后占的外框
    var bounds: CGRect {
        guard rotation != 0 else { return frame }
        let t = CGAffineTransform(translationX: frame.midX, y: frame.midY).rotated(by: rotation).translatedBy(x: -frame.midX, y: -frame.midY)
        return frame.applying(t)
    }
}

extension BoardItem {
    /// 长图：封面只露开头一截
    var isLong: Bool { if case .card(let card) = face { card.form == .long } else { false } }

    /// 转过之后占的外框，用来找视野里的卡
    var bounds: CGRect { placement.bounds }

    /// 世界坐标里的点落不落在这张卡上（考虑旋转）
    func contains(_ p: CGPoint) -> Bool {
        let f = placement.frame
        let local = CGPoint(x: p.x - f.midX, y: p.y - f.midY).applying(CGAffineTransform(rotationAngle: -placement.rotation))
        return abs(local.x) <= f.width / 2 && abs(local.y) <= f.height / 2
    }
}
