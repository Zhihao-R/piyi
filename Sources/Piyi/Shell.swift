import SwiftUI
import Library
import Canvas
import Tokens

/// 窗口：左边侧边栏，右边画布；放大查看盖在画布上
struct Shell: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                ZStack {
                    if let canvas = model.canvas {
                        // 画布铺到侧边栏、工具栏、讨论栏底下；它们各盖住多宽，告诉画布让开
                        GeometryReader { geo in
                            CanvasHost(canvas: canvas, covered: geo.safeAreaInsets).ignoresSafeArea()
                            // 工具栏不铺底：按钮直接浮在画布上，顶上垫一层渐隐托住标题
                            LinearGradient(colors: [Palette.titleShade.color, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: geo.safeAreaInsets.top + Chrome.inset)
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                        }
                        if let hint = model.emptyHint {
                            Text(hint).font(.callout).foregroundStyle(.secondary).allowsHitTesting(false).transition(.opacity)
                        }
                        // 放大查看时只剩眼前这张卡：搜索栏收起来
                        SearchLayer(model: model)
                            .opacity(model.detail == nil ? 1 : 0)
                            .allowsHitTesting(model.detail == nil)
                    } else if let failure = model.failure {
                        Text(failure).foregroundStyle(.secondary)
                    }
                    detailLayer
                }
                .overlay(alignment: .top) {
                    if let notice = model.notice {
                        HStack(spacing: 12) {
                            Text(notice.text)
                            if notice.undo != nil {
                                Button("撤销") { model.undoNotice() }.buttonStyle(.borderless)
                            }
                        }
                        .noticeStyle()
                        .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                // 切画板时放大查看跟着画布换内容一起变
                .animation(model.swapping ? .swapSpan : .fade, value: model.detail)
                .animation(.fade, value: model.closing)
                .animation(.fade, value: model.notice)
                .animation(.fade, value: model.emptyHint)
                StatusBar(model: model)
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .inspector(isPresented: Bindable(model.discussions).isOpen) {
            DiscussionPanel(model: model)
                .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        }
        .sheet(isPresented: $model.showsOnboarding) { Onboarding(model: model) }
        .sheet(item: $model.sortSettings) { SortSettings(board: $0, model: model) }
        .navigationTitle(model.title)
        .toolbar {
            // 没有可退的就不摆后退按钮，免得一颗点不动的圆圈最显眼
            if !model.history.isEmpty {
                ToolbarItem(placement: .navigation) {
                    Button { model.back() } label: { Image(systemName: "chevron.backward") }
                        .help("后退")
                }
            }
            if case .board? = model.location {
                ToolbarItem {
                    Button { model.canvas?.addNote() } label: { Label("添加", systemImage: "plus") }
                        .labelStyle(.titleAndIcon)
                        .help("在画板上写一张文字卡（也可以双击空白处）")
                }
            }
            if case .collection? = model.location {
                ToolbarItem {
                    Picker("视图", selection: $model.libraryView) {
                        ForEach(LibraryView.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("资料库按什么排：默认从新到旧，或者按天、按颜色、按来源分组")
                }
            }
            if model.location == .collection(.unplaced) {
                ToolbarItem {
                    Button("分拣这些卡") { model.resortUnplaced() }
                        .help("把这里的卡重新分拣一遍，有把握的放进对应的画板")
                }
            }
            // 有声音在播：不论在哪个画板、开没开放大查看，都能在这里暂停、回到那张卡
            if model.audio.track != nil {
                ToolbarItem { NowPlaying(audio: model.audio) { model.detail = $0 } }
            }
            // 展开、收起讨论栏；收起时有新回答，按钮上亮一个点
            ToolbarItem(placement: .primaryAction) {
                Button { model.discussions.isOpen.toggle() } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .overlay(alignment: .topTrailing) { if model.discussions.hasUnread { UnreadDot().offset(x: 3, y: -2) } }
                }
                .help("讨论")
            }
        }
        .alert("重命名画板", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } }),
               presenting: model.renaming) { board in
            RenameField(name: board.name, label: String(localized: "画板名")) { model.rename(board, to: $0) }
        }
        .alert("重命名讨论", isPresented: Binding(get: { model.discussions.renaming != nil }, set: { if !$0 { model.discussions.renaming = nil } }),
               presenting: model.discussions.renaming) { summary in
            RenameField(name: summary.discussion.displayName, label: String(localized: "讨论名")) { model.discussions.rename(summary, to: $0) }
        }
    }

    /// 放大查看：压暗的底放在外面，按方向键换卡时它不跟着闪
    @ViewBuilder private var detailLayer: some View {
        if model.detail != nil, !model.closing {
            Palette.backdrop.color.ignoresSafeArea()
                // 双击不算关：在画板上双击已选中的卡，第一下就打开了，第二下落在这里
                .onTapGesture { if (NSApp.currentEvent?.clickCount ?? 1) < 2 { model.closeDetail() } }
                // 切画板关掉时，暗底已经挪进旧画面跟它一起淡，这里直接撤；面板照样当作旧画面里的一张淡出
                .transition(.asymmetric(insertion: .opacity, removal: model.swapping ? .identity : .opacity))
        }
        if let store = model.store {
            // 每张卡一块面板：换了卡是新的一块（播放器、翻到第几张图都不带过去），换下去的那块自己淡完
            ForEach(model.panels, id: \.self) { id in
                let current = id == model.detail
                DetailView(store: store, card: id, focus: current ? model.focus : nil, audio: model.audio, discuss: discussButton(id),
                           spot: current ? model.spot : nil, stayed: current && model.stayed, closing: current && model.closing, away: !current)
                    { model.closeDetail() }
                    follow: { model.follow($0, of: id) }
                    refetch: { model.refetch(id) }
                    rewrite: { model.rewrite(id, to: $0) }
                    lift: { model.lift($0) }
                    closed: { current ? model.finishClosing() : model.dismissed(id) }
                    // 进来、淡出都由它自己做；淡出途中不接点击
                    .transition(.identity)
                    .allowsHitTesting(current)
            }
        }
    }

    /// 放大查看里出处那一行右端的按钮：叫法和操作条、右键菜单同一处定
    private func discussButton(_ card: Int64) -> DetailView.Action {
        let entry = model.discussions.entry(for: [card])
        return DetailView.Action(title: entry.title, enabled: entry.enabled) { model.discussions.discuss([card]) }
    }
}

private struct RenameField: View {
    let name: String
    let label: String
    let done: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField(label, text: $text)
            .onAppear { text = name }
        Button("好") { done(text) }
        Button("取消", role: .cancel) {}
    }
}

/// 侧边栏：两个卡片视图，下面是画板列表（按最近打开排序），废纸篓钉在最底下。画板可以拖到画布上生成入口，卡片拖到画板上就移过去。
/// 不用系统的 List：它插行、删行都是瞬间的，拖卡时弹出「移出」那一行要跟着弹簧把下面的行推开
struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SidebarHeader(title: String(localized: "资料库"))
                row(String(localized: "全部卡片"), icon: "square.grid.2x2", to: .collection(.all))
                row(String(localized: "未归类"), icon: "tray", to: .collection(.unplaced))
                SidebarHeader(title: String(localized: "sidebar.boards", defaultValue: "画板")) {
                    Button { model.newBoard() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("新建画板")
                }
                .padding(.top, 12)
                ForEach(model.boards) { board in
                    row(board.name, icon: "rectangle.on.rectangle", to: .board(board.id!), accepts: model.dragging && model.location != .board(board.id!)) { drop($0, on: board) }
                        .draggable(CanvasView.boardPrefix + "\(board.id!)")
                        .contextMenu {
                            Button("重命名…") { model.renaming = board }
                            Button("分拣设置…") { model.sortSettings = board }
                            Button("删除画板…") { model.delete(board) }
                        }
                }
                DiscussionGroup(model: model)
            }
            .padding(.horizontal, 10)
        }
        // 废纸篓钉在左下角，不随画板列表滚走：往上拖是归进画板，往左下角甩是拿走
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // 在画板里一拖起卡，废纸篓上面就弹出一行：移出这个画板（卡还在资料库里）
                if let board = model.boards.first(where: { $0.id == model.leaving }) {
                    SidebarRow(title: String(localized: "移出「\(board.name)」"), icon: "rectangle.badge.minus", accepts: model.dragging) { take($0) }
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
                row(String(localized: "废纸篓"), icon: "trash", to: .collection(.trash), accepts: model.dragging && model.location != .collection(.trash)) { trash($0) }
                    .contextMenu { Button("清空废纸篓…") { model.emptyTrash() } }
            }
            .padding(10)
            .animation(.spring(Motion.lift), value: model.leaving)
        }
    }

    /// 点了去那里的一行；能收卡的再给出怎么收
    private func row(_ title: String, icon: String, to place: CanvasContent, accepts: Bool = false, accept: (([String]) -> Bool)? = nil) -> some View {
        SidebarRow(title: title, icon: icon, selected: model.location == place, accepts: accepts, accept: accept)
            .onTapGesture { if model.location != place { model.go(place) } }
    }

    /// 从画布拖来的卡片：移到这个画板，按住 ⌥ 是放一份（从废纸篓拖来的先恢复）
    private func drop(_ strings: [String], on board: Board) -> Bool {
        guard let items = dragged(strings), board.id != model.canvas?.board else { return false }
        model.put(items, into: board.id!, keepingHere: CanvasView.keepsHere)
        return true
    }

    /// 从画布拖来的卡片：放进废纸篓
    private func trash(_ strings: [String]) -> Bool {
        guard let items = dragged(strings), model.location != .collection(.trash) else { return false }
        model.trash(items)
        return true
    }

    /// 从画板拖来的卡片：移出这个画板
    private func take(_ strings: [String]) -> Bool {
        guard let items = dragged(strings) else { return false }
        model.removeFromBoard(items)
        return true
    }

    private func dragged(_ strings: [String]) -> [BoardItem]? { model.draggedItems(strings) }
}

/// 侧边栏的讨论组：有了第一段讨论才出现，按最近一次动静排；3 天没动静的收进组底折叠的「已归档」。
/// 卡拖到讨论行上就放上它的桌，讨论栏不切换
private struct DiscussionGroup: View {
    let model: AppModel
    @State private var showsArchived = false

    var body: some View {
        let d = model.discussions
        let now = Date.now
        let active = d.all.filter { !$0.isArchived(now: now) }, archived = d.all.filter { $0.isArchived(now: now) }
        if !d.all.isEmpty {
            SidebarHeader(title: String(localized: "sidebar.discussions", defaultValue: "讨论")).padding(.top, 12)
            ForEach(active) { row($0) }
            if !archived.isEmpty {
                Button { showsArchived.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(showsArchived ? 90 : 0)).frame(width: 20)
                        Text("已归档")
                    }
                    .padding(.leading, 8).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                if showsArchived { ForEach(archived) { row($0) } }
            }
        }
    }

    private func row(_ summary: DiscussionSummary) -> some View {
        let d = model.discussions
        return SidebarRow(title: summary.discussion.displayName, icon: "bubble.left.and.bubble.right",
                          selected: d.isOpen && d.current == summary.id, dot: summary.unread, accepts: model.dragging) { strings in
            guard let cards = model.draggedCards(strings) else { return false }
            d.place(cards, onto: summary)
            return true
        }
        .onTapGesture { d.open(summary.id) }
        .contextMenu {
            Button("重命名…") { d.renaming = summary }
            Button("删除…") { d.delete(summary) }
        }
    }
}

/// 有你还没看过的回答：侧边栏讨论行的行尾、工具栏讨论按钮上
private struct UnreadDot: View {
    var body: some View { Circle().fill(Palette.accent.color).frame(width: 7, height: 7) }
}

/// 分组标题；画板那一组右边带新建的「+」
private struct SidebarHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            accessory.foregroundStyle(.secondary)
        }
        .padding(.leading, 4).padding(.trailing, 8).frame(height: 20)
    }
}

extension SidebarHeader where Accessory == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// 侧边栏的一行，尺寸照系统侧边栏：32 点高，圆角铺底。选中的铺浅底；接得住的卡片拖到上面时铺深一档。
/// 落进去的反馈是拖着的那一摞缩进去（见 Outgoing.sink）
private struct SidebarRow: View {
    let title: String, icon: String
    var selected = false
    /// 行尾的点：讨论有你还没看过的回答
    var dot = false
    /// 眼下拖着的东西这一行接不接得住：接不住的不亮
    var accepts = false
    var accept: (([String]) -> Bool)?
    @State private var targeted = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            if dot { UnreadDot() }
        }
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(targeted ? AnyShapeStyle(.tertiary) : selected ? AnyShapeStyle(.quaternary)
                                                           : hovered ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.spring(Motion.lift), value: targeted)
        .dropDestination(for: String.self) { strings, _ in accept?(strings) ?? false } isTargeted: { targeted = $0 && accepts }
    }
}

/// 盖在画布上的搜索栏和文字面板。资料库里有意选了卡，搜索栏变形成操作栏
struct SearchLayer: View {
    let model: AppModel
    @Namespace private var bar

    private var search: SearchModel { model.search }

    var body: some View {
        ZStack {
            GlassEffectContainer {
                if !model.picked.isEmpty {
                    SelectionBar(model: model, bar: bar)
                } else {
                    SearchBar(search: search, bar: bar, focusRequest: model.searchFocus)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .animation(.spring(Motion.lift), value: model.picked.isEmpty)
            if let panel = search.panel {
                ReadingPanel(search: search, panel: panel)
                    .padding(.trailing, Chrome.inset)
                    .padding(.bottom, Chrome.searchReserve)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.opacity.combined(with: .offset(x: 16)))
            }
        }
        .animation(.fade, value: search.panel?.kind)
        .animation(.fade, value: search.panel == nil)
    }
}

/// 把画布（AppKit 视图）放进 SwiftUI
struct CanvasHost: NSViewRepresentable {
    let canvas: CanvasView
    let covered: EdgeInsets
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.covered = NSEdgeInsets(top: covered.top, left: covered.leading, bottom: covered.bottom, right: covered.trailing)
    }
}

extension View {
    /// 一句提示的样子：玻璃胶囊，离边 16 点。窗口顶部的提示和片羽在后台时屏幕右上角的提示共用；
    /// 屏幕上的那条（prominent）胶囊更宽松，配大一号的字
    func noticeStyle(prominent: Bool = false) -> some View {
        padding(.horizontal, prominent ? 22 : 16).padding(.vertical, prominent ? 14 : 10).glassEffect().padding(16)
    }
}
