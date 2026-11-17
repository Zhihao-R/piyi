import SwiftUI
import Library
import Canvas
import Tokens

/// Window: sidebar on the left, canvas on the right; detail view covers the canvas
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
                        // The canvas extends under the sidebar, toolbar and discussion bar; tell the canvas how much each covers so it makes room
                        GeometryReader { geo in
                            CanvasHost(canvas: canvas, covered: geo.safeAreaInsets).ignoresSafeArea()
                            // The toolbar has no background: buttons float directly on the canvas, with a fade at the top holding the title
                            LinearGradient(colors: [Palette.titleShade.color, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: geo.safeAreaInsets.top + Chrome.inset)
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                        }
                        if let hint = model.emptyHint {
                            Text(hint).font(.callout).foregroundStyle(.secondary).allowsHitTesting(false).transition(.opacity)
                        }
                        // In detail view only this one card remains: the search bar is put away
                        SearchLayer(model: model)
                            .opacity(model.detail == nil ? 1 : 0)
                            .allowsHitTesting(model.detail == nil)
                    } else if let failure = model.failure {
                        Text(failure).foregroundStyle(.secondary)
                    }
                    detailLayer
                }
                .overlay(alignment: .top) {
                    // Download progress and notices stack, so they don't cover each other when both show
                    VStack(spacing: 0) {
                        if model.modelDownload != nil || model.modelDownloadFailed || model.modelJustReady {
                            ModelDownloadBar(model: model)
                                .transition(.opacity.combined(with: .offset(y: -6)))
                        }
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
                }
                // When switching boards, the detail view changes along with the canvas's content
                .animation(model.swapping ? .swapSpan : .fade, value: model.detail)
                .animation(.fade, value: model.closing)
                .animation(.fade, value: model.notice)
                .animation(.fade, value: model.modelDownload == nil)
                .animation(.fade, value: model.modelDownloadFailed)
                .animation(.fade, value: model.modelJustReady)
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
            // No back button when there's nothing to go back to, so an unclickable circle isn't the most prominent thing
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
            // Something is playing: whatever board you're in, detail view open or not, you can pause here and go back to that card
            if model.audio.track != nil {
                ToolbarItem { NowPlaying(audio: model.audio) { model.detail = $0 } }
            }
            // Expand/collapse the discussion bar; when collapsed with a new answer, a dot lights up on the button
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

    /// Detail view: the dimmed backdrop sits outside, so it doesn't flash when switching cards with arrow keys
    @ViewBuilder private var detailLayer: some View {
        if model.detail != nil, !model.closing {
            Palette.backdrop.color.ignoresSafeArea()
                // A double-click doesn't count as closing: double-clicking a selected card on a board opens it on the first click, and the second lands here
                .onTapGesture { if (NSApp.currentEvent?.clickCount ?? 1) < 2 { model.closeDetail() } }
                // When closed by switching boards, the dark backdrop has already moved into the old view to fade with it, so remove it here directly; the panel still fades out as part of the old view
                .transition(.asymmetric(insertion: .opacity, removal: model.swapping ? .identity : .opacity))
        }
        if let store = model.store {
            // One panel per card: a changed card gets a new panel (player and current image don't carry over), the swapped-out one finishes fading on its own
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
                    // It handles entering and fading out itself; no clicks while fading out
                    .transition(.identity)
                    .allowsHitTesting(current)
            }
        }
    }

    /// Buttons at the right end of the source row in detail view: labels are defined in the same place as the action bar and context menu
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

/// Sidebar: two card views, then the board list (sorted by most recently opened), Trash pinned at the bottom. Boards can be dragged onto the canvas to create entries; dragging cards onto a board moves them there.
/// Not the system List: its row inserts and deletes are instant, but while dragging cards the "Remove" row that pops up has to push the rows below aside with a spring
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
        // Trash is pinned to the bottom left and doesn't scroll with the board list: dragging up files into boards, flinging to the bottom left takes away
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // Once you start dragging a card in a board, a row pops up above Trash: Remove from This Board (the card stays in the library)
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

    /// A row that goes somewhere when clicked; ones that accept cards also say how to collect
    private func row(_ title: String, icon: String, to place: CanvasContent, accepts: Bool = false, accept: (([String]) -> Bool)? = nil) -> some View {
        SidebarRow(title: title, icon: icon, selected: model.location == place, accepts: accepts, accept: accept)
            .onTapGesture { if model.location != place { model.go(place) } }
    }

    /// Cards dragged from the canvas: move to this board; holding ⌥ adds a copy (ones dragged from Trash are restored first)
    private func drop(_ strings: [String], on board: Board) -> Bool {
        guard let items = dragged(strings), board.id != model.canvas?.board else { return false }
        model.put(items, into: board.id!, keepingHere: CanvasView.keepsHere)
        return true
    }

    /// Cards dragged from the canvas: move to Trash
    private func trash(_ strings: [String]) -> Bool {
        guard let items = dragged(strings), model.location != .collection(.trash) else { return false }
        model.trash(items)
        return true
    }

    /// Cards dragged from a board: remove from this board
    private func take(_ strings: [String]) -> Bool {
        guard let items = dragged(strings) else { return false }
        model.removeFromBoard(items)
        return true
    }

    private func dragged(_ strings: [String]) -> [BoardItem]? { model.draggedItems(strings) }
}

/// The sidebar's discussion group: appears once there's a first discussion, sorted by latest activity; those inactive for 3 days go into a collapsed "Archived" at the bottom of the group.
/// Dragging a card onto a discussion row puts it on that discussion's table, without switching the discussion bar
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

/// There are answers you haven't seen: at the end of the sidebar discussion row and on the toolbar discussion button
private struct UnreadDot: View {
    var body: some View { Circle().fill(Palette.accent.color).frame(width: 7, height: 7) }
}

/// Group title; the boards group has a "+" for new on its right
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

/// A sidebar row, sized like the system sidebar: 32 pt tall, rounded background. Selected gets a light background; when acceptable cards are dragged over it, one shade darker.
/// The drop feedback is the dragged stack shrinking in (see Outgoing.sink)
private struct SidebarRow: View {
    let title: String, icon: String
    var selected = false
    /// The dot at the end of the row: the discussion has answers you haven't seen
    var dot = false
    /// Whether this row accepts what's currently being dragged: rows that don't, don't light up
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

/// The search bar and text panel over the canvas. With cards deliberately selected in the library, the search bar morphs into the action bar
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

/// Put the canvas (an AppKit view) into SwiftUI
struct CanvasHost: NSViewRepresentable {
    let canvas: CanvasView
    let covered: EdgeInsets
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.covered = NSEdgeInsets(top: covered.top, left: covered.leading, bottom: covered.bottom, right: covered.trailing)
    }
}

extension View {
    /// The look of a hint: a glass capsule, 16 pt from the edge. Shared by hints at the top of the window and at the top right of the screen when Piyi is in the background;
    /// the on-screen one (prominent) is a roomier capsule with one size larger text
    func noticeStyle(prominent: Bool = false) -> some View {
        padding(.horizontal, prominent ? 22 : 16).padding(.vertical, prominent ? 14 : 10).glassEffect().padding(16)
    }
}

/// Floating at the top of the window while the local model downloads in the background; says search is ready when done, offers a retry if it stopped
struct ModelDownloadBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let progress = model.modelDownload {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                Text("下载本机模型")
                Text("\(Int(progress * 100))%").foregroundStyle(.secondary).monospacedDigit()
            } else if model.modelDownloadFailed {
                Text("下载中断")
                Button("重试") { model.downloadLocalModel() }.buttonStyle(.link)
            } else {
                Label("可以搜索了", systemImage: "checkmark.circle.fill")
            }
        }
        // Same glass capsule as the search bar and selection bar at the bottom
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .frame(height: Chrome.searchHeight)
        .glassEffect(.regular, in: .capsule)
        .padding([.horizontal, .top], Chrome.inset)
    }
}
