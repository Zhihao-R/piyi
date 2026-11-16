import AVKit
import WebKit
import AppKit
import Network
import Observation
import Synchronization
import Library
import Intelligence
import Canvas
import Tokens

/// 界面外壳的状态：资料库、画板列表、当前在看什么、后退记录、浮层的层级
@MainActor @Observable
final class AppModel {
    private(set) var store: Store?
    private(set) var canvas: CanvasView?
    private(set) var boards: [Board] = []
    /// 画布上正在看的：一个画板，或全部卡片 / 未归类 / 废纸篓
    private(set) var location: CanvasContent?
    /// 从画板入口进去时记下来处，后退时回去
    private(set) var history: [CanvasContent] = []
    /// 放大查看的卡
    var detail: Int64? {
        didSet {
            if let detail, detail != oldValue {
                noteOpened(detail)
                // 已经在看结果了：晚到的云端结果不再把卡从手底下挪走
                search.settle()
            }
            if detail != oldValue {
                // 换下去的那块面板留着自己淡完；已经缩回卡片的不用再淡
                if let old = oldValue, closing { panels.removeAll { $0 == old } }
                if let detail { panels.removeAll { $0 == detail }; panels.append(detail) }
                // 换了卡、关了：不再对着画布上哪张，也不在关的途中。从画布打开的由 open 接着记下来处
                (spot, closing, stayed) = (nil, false, false)
                detailHome = detail == nil ? nil : location
                if oldValue == nil { fromCanvas = false }
            }
            if focus?.card != detail { focus = nil }
        }
    }
    /// 全应用那一个播放器：声音不跟着画板、放大查看走
    let audio = AudioPlayer()
    /// ⌘F 每按一次加一，搜索栏看到就把光标接过去
    var searchFocus = 0
    /// 眼前一张卡也没有时，画布正中的一行提示
    private(set) var emptyHint: String?
    /// 放大查看要对准的一段：讨论里点了引用，滚到那一段并闪一下，视频从那一秒播
    var focus: Focus?

    struct Focus: Equatable {
        var card: Int64
        /// 那一段现在的原文；nil 是整张卡
        var text: String?
        var seconds: Int?
        /// 同一处再点一次也再闪一次
        let id = UUID()
    }
    /// 正在重命名的画板
    var renaming: Board?
    /// 选中有变化、进出裁剪时加一，依赖画布状态的菜单项据此刷新
    private(set) var canvasTick = 0
    /// 资料库里有意选中的卡（点一下只是看，不算）。有选中时底部的搜索栏换成对它们做事的那一条；
    /// 画板里点一下就选中、搜索结果聚在眼前时，都不算
    private(set) var picked: [BoardItem] = []
    /// 正在这个画板里拖卡：一拖起来，侧边栏的废纸篓上面就多一行「移出这个画板」，等拖到侧边栏时已经摆好
    private(set) var leaving: Int64?
    /// 正把卡拖出画布：侧边栏的画板、废纸篓这时才接得住，才亮
    private(set) var dragging = false
    /// 资料库按什么排：默认从新到旧一整片，或者按天、按颜色、按来源分组。记着，下次打开还是这样
    var libraryView = LibraryView.recent {
        didSet {
            guard libraryView != oldValue else { return }
            canvas?.grouping = libraryView.grouping
            let view = libraryView
            Task { try? await store?.setSetting(Self.libraryViewKey, view) }
        }
    }
    static let libraryViewKey = "libraryView"
    private(set) var failure: String?
    /// 窗口顶部的一句临时提示（「已经收过」之类），几秒后消失
    private(set) var notice: Notice?
    /// 正在改分拣设置的画板
    var sortSettings: Board?
    private(set) var collector: Collector!
    private let network = NWPathMonitor()
    private(set) var online = true

    // 模型接入、理解和分拣
    private(set) var understander: Understander?
    private(set) var sorter: Sorter?
    // 搜索和灵感
    private(set) var searcher: Searcher?
    private(set) var inspirer: Inspirer?
    @ObservationIgnored private(set) lazy var search = SearchModel(model: self)
    // 和 AI 讨论
    private(set) var discussionKernel: DiscussionKernel?
    @ObservationIgnored private(set) lazy var discussions = DiscussionModel(model: self)
    private(set) var embedder: LocalEmbedder?
    /// 状态栏：当前画板和资料库各几张、正在处理、等待密钥、失败
    private(set) var counts = Counts()
    /// 本机模型下载进度 0～1；nil 表示没在下载
    private(set) var modelDownload: Double?
    /// 要填密钥的云端服务方，设置页按它们逐个显示密钥框
    private(set) var cloud: [any Keyed] = []
    /// 各服务方的密钥状态、本机模型在不在：填密钥、下完模型、理解有进展（可能发现密钥被拒）时更新
    private(set) var keyStates: [String: KeyState] = [:]
    /// 云端怎么接：哪家服务商、哪个模型、讨论时要不要思考
    private(set) var cloudSetup = CloudSetup.saved
    /// 刚换的模型在 OpenRouter 的列表里没查到
    private(set) var cloudModelUnknown = false
    /// 云端能用了：密钥没问题，自定义服务商的地址和模型也填了
    private(set) var cloudReady = false
    /// 最近一次请求被服务商退回的原因：模型下线了、没开通、地址不对，设置页在模型那一行下面说出来
    private(set) var cloudFailure: String?
    @ObservationIgnored private var cloudAPI: Cloud?
    private(set) var localModelReady = false
    /// 第一次打开的引导：填密钥、下载本机模型、装浏览器扩展、连手机
    var showsOnboarding = false
    let browserExtension = BrowserExtension()
    let phoneInbox = PhoneInbox()

    func start(quickCollect: QuickCollect) async {
        guard store == nil else { return }
        do {
            // 环境变量 COLLAGE_ROOT 指定另一个资料库目录（试新装用户时用）
            let root = ProcessInfo.processInfo.environment["COLLAGE_ROOT"].map { URL(fileURLWithPath: $0) }
            let store = try Store(root: root ?? Store.defaultRoot)
            self.store = store
            let interaction = interaction
            let embedder = LocalEmbedder(file: LocalModel.file(in: store.root)) { interaction.isRecent }
            // 自查时从环境变量读 OpenRouter 的密钥，不碰密钥文件（和真实云端测试一样）。这把只给 OpenRouter，别家照常读各自的
            let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
            let cloudAPI = Cloud(cloudSetup, key: envKey.map { key -> @Sendable (Vendor) -> String? in
                { $0 == .openRouter ? key : KeyFile.key(for: $0.rawValue) }
            })
            self.cloudAPI = cloudAPI
            let gateway = Gateway(embedder: embedder, generators: [cloudAPI], judges: [Jev(via: cloudAPI)], judging: [cloudAPI.judging],
                                  transcribers: [SystemSpeech()], conversers: [cloudAPI])
            self.embedder = embedder
            cloud = [cloudAPI]
            refreshModelStates()
            understander = Understander(store: store, gateway: gateway) { [weak self] in
                Task { @MainActor in self?.understandingProgressed() }
            }
            sorter = Sorter(store: store, gateway: gateway, placer: SortPlacer(store: store)) { [weak self] written in
                Task { @MainActor in self?.sortPlaced(written) }
            }
            let searcher = Searcher(store: store, gateway: gateway)
            self.searcher = searcher
            inspirer = Inspirer(searcher: searcher, gateway: gateway)
            discussionKernel = DiscussionKernel(store: store, gateway: gateway, tools: [FindCards(searcher: searcher), PickRandomCards(searcher: searcher)])
            collector = Collector(model: self, extractor: Extractor(models: ExtractionAssist(gateway: gateway), browser: browserExtension.reader))
            // 上次退出时还在抽取的占位卡：有网址的转成残缺卡，下面联网检查时重新抓；其余的原件还在收件箱里，重收时由查重认出来
            try await store.recoverUnfinished()
            // 以前被当成正常卡留下的拦截页：认一遍（只做一次），认出来的同样转成残缺卡重新抓
            try await store.demoteChallengePagesOnce()
            collector.completeUnfinishedBodies()
            let canvas = CanvasView(store: store)
            canvas.delegate = self
            self.canvas = canvas
            audio.soundingChanged = { [weak self] in self?.canvas?.sounding = self?.audio.sounding }
            if let view = try? await store.setting(Self.libraryViewKey, as: LibraryView.self) { libraryView = view }
            // 第一次打开停在示例画板：它和「我的画板」同一刻建成，按最近打开排谁在前说不准。
            // 自查用：COLLAGE_SAMPLE="画板名" 在现有资料库里再放一份示例画板并打开它，看示例摆得怎样
            var landing: Int64?
            if try await store.boards().isEmpty { landing = try await firstLaunch(store) }
            else if let name = ProcessInfo.processInfo.environment["COLLAGE_SAMPLE"] { landing = try await addSample(store, named: name) }
            try await refreshBoards()
            try await closeSampleSortingOnce(store)
            if let id = landing ?? boards.first?.id { go(.board(id)) }
            discussions.reload()
            for board in boards where board.collage == nil { boardChanged(board.id!) }
            Task.detached(priority: .utility) { try? await store.completeThumbnails() }
            installMonitors()
            watchNetwork()
            // 快捷键、服务菜单、浏览器扩展、手机收的都先存在收件箱里，只进资料库，等以后自动分拣；
            // 查过重才提示，各入口同一组说法（Receipt）
            connectBrowsers(quickCollect)
            await phoneInbox.start(store: store) { [weak self] inbox, heard in
                self?.collector.drain(inbox) { arrivals, receipt in
                    heard(arrivals, receipt)
                    self?.notify(receipt.text)
                }
            }
            quickCollect.start { [weak self] in self?.collector.drainLocal(quick: quickCollect) } tell: { [weak self] in self?.notify($0) }
            // 退出时排着队的卡，这次接着算、接着分
            understander?.kick()
            sorter?.kick()
            loadLocalModel()
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [embedder] _ in
                // 不释放的话 llama.cpp 在进程退出时崩溃
                embedder.unload()
            }
            try await prepareOnboarding(store)
            // 自查用：COLLAGE_TRY="一句话" 启动后自动输入并回车，COLLAGE_TRY="✦" 按灵感按钮，COLLAGE_TRY="…一句话" 只输入不回车，
            // COLLAGE_TRY="💬一句话" 把画板上第一张卡放上讨论的桌再问这句
            if let line = ProcessInfo.processInfo.environment["COLLAGE_TRY"] {
                try? await Task.sleep(for: .seconds(3))
                if line == "✦" { search.inspireHere() } else if line.hasPrefix("…") { search.text = String(line.dropFirst()) }
                else if line.hasPrefix("💬"), let board = boards.first?.id,
                        let card = (try? await store.items(on: board))?.compactMap(\.placement.cardID).first {
                    discussions.discuss([card])
                    try? await Task.sleep(for: .seconds(1))
                    discussions.send(String(line.dropFirst()))
                } else { search.text = line; search.submit() }
            }
        } catch {
            failure = String(localized: "资料库打不开：\(error.localizedDescription)")
        }
    }

    /// 第一次打开：建「我的画板」和「示例」画板，返回示例画板
    private func firstLaunch(_ store: Store) async throws -> Int64 {
        _ = try await store.createBoard(String(localized: "我的画板"))
        let sample = try await addSample(store, named: String(localized: "示例"))
        Seed.board = sample
        return sample
    }

    /// 建一块示例画板，示例数据走正常的收集流程，按清单里的位置摆好
    private func addSample(_ store: Store, named name: String) async throws -> Int64 {
        let sample = try await store.createBoard(name).id!
        // 示例卡的主题不该把你自己的东西吸过去；示例卡自己也不分进你的画板
        try await store.setSorting(sample, autoSort: false, rule: nil)
        try await refreshBoards()
        try await canvas?.show(.board(sample))
        let seed = Seed.sources()
        collector.collect(seed.map(\.source), into: sample, at: .zero, presets: seed.map(\.preset)) { [weak self] _ in
            Task { try? await store.markSorted(on: sample) }
            // 打开画板时示例卡还没收进来，镜头是按空画板取的景：收完了、镜头也没被挪开过，就滑到全景
            if let canvas = self?.canvas, canvas.board == sample, canvas.isAtPanorama { canvas.fitAll(animated: true) }
        }
        return sample
    }

    /// 已经建好的老资料库：示例画板的自动分拣关一次，之后你打开了就不再动
    private func closeSampleSortingOnce(_ store: Store) async throws {
        guard !Seed.sortingClosed else { return }
        if let sample = boards.first(where: { $0.id == Seed.board }) { try await store.setSorting(sample.id!, autoSort: false, rule: sample.rule) }
        Seed.sortingClosed = true
        try await refreshBoards()
    }

    // MARK: 提示、网络

    struct Notice: Identifiable, Equatable {
        /// 每次更新换一个：到点时只收掉没再更新过的
        let id = UUID()
        var text: String
        /// 点「撤销」退回什么
        var undo: Undo?
    }

    enum Undo: Equatable {
        /// 分拣放进的摆放：全部拿走，卡仍然算分拣过
        case sorted([Placement])
        /// 刚放进废纸篓的卡：恢复
        case trashed([Int64])
        /// 刚移出画板的摆放：放回原处
        case taken([Placement])
    }

    func notify(_ text: String) { post(Notice(text: text)) }

    /// 打开卡片的原链接或原文件
    func follow(_ url: URL, of card: Int64) {
        NSWorkspace.shared.open(url)
        record(.followed, [card])
    }

    /// 放大查看停留满一秒才记一次回看：按方向键连着翻过去的不算「又看过」
    private func noteOpened(_ card: Int64) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            if detail == card { record(.opened, [card]) }
        }
    }

    /// 放大查看此刻对着画布上哪张卡：从画布打开时是那张，关的时候是要缩回去的那张。按方向键换来的、从讨论栏打开的没有
    private(set) var spot: Spot? {
        didSet { if let old = oldValue, old.placement != spot?.placement { canvas?.reveal(old) } }
    }
    /// 放大查看是从画布上打开的：关的时候缩回画布上那张
    private var fromCanvas = false
    /// 离开时开着放大查看的地方，各记着开的是哪张、是不是从画布打开的
    private var parked: [CanvasContent: (card: Int64, fromCanvas: Bool)] = [:]
    /// 放大查看正在关：缩回画布上那张卡，做完才真的关
    private(set) var closing = false
    /// 屏幕上的放大查看面板：正在看的那张，加上刚换下去、还在淡出的。面板里有原生的文字和播放器控件，
    /// 整块直接拿掉会一下消失，所以换下去的留着原来那份，自己淡完再拿掉
    private(set) var panels: [Int64] = []
    /// 这张是切回画板时原样开着的：不飞不长，跟着画布一起淡入
    private(set) var stayed = false
    /// 正跟着画布换内容（切画板）：压暗的底变亮变暗用画布换内容的全程，跟它同起同止
    private(set) var swapping = false
    /// 开着的这张属于哪个地方
    private var detailHome: CanvasContent?

    /// 从画布上打开一张卡：放大查看从它长出来
    func open(_ item: BoardItem) {
        guard let card = item.placement.cardID else { return }
        detail = card
        fromCanvas = true
        spot = canvas?.spot(item.id)
    }

    /// 放大查看把卡拿起来、放回去：飞着的时候画布上那张不见，不飞了就放回原处
    func lift(_ up: Bool) {
        guard let spot else { return }
        if up { canvas?.hide(spot) } else { canvas?.reveal(spot) }
    }

    /// 关掉放大查看：从画布打开、那张卡还在眼前就先缩回去，否则直接淡出
    func closeDetail() {
        guard let detail, !closing else { return }
        spot = fromCanvas ? spot.flatMap { canvas?.spot($0.placement) } ?? canvas?.spot(ofCard: detail) : nil
        if spot == nil { self.detail = nil } else { closing = true }
    }

    /// 缩回去做完了。途中已经换了卡（方向键、点了别的卡）就不关
    func finishClosing() {
        if closing { detail = nil }
    }

    /// 换下去的面板淡完了
    func dismissed(_ card: Int64) {
        if card != detail { panels.removeAll { $0 == card } }
    }

    /// 放大查看里按左右键：换到眼前顺序里的上一张、下一张。到头了就不动
    func step(_ by: Int) {
        guard let detail, let next = canvas?.neighbor(of: detail, by: by) else { return }
        self.detail = next
    }

    /// 放大查看里点了「重新抓取」：回到画布上看它重新抽取
    func refetch(_ card: Int64) {
        detail = nil
        Task { if let full = try? await store?.card(card) { collector.refetch(full) } }
    }

    /// 记一次回看：后台写，写不进也不打扰你
    func record(_ revisit: Revisit, _ cards: [Int64], board: Int64? = nil) {
        guard let store else { return }
        Task { try? await store.record(revisit, cards, board: board) }
    }

    /// 带撤销的停得久一些，来得及点
    private func post(_ new: Notice) {
        notice = new
        Task {
            try? await Task.sleep(for: .seconds(new.undo == nil ? Motion.notice : Motion.notice * 2))
            if notice?.id == new.id { notice = nil }
        }
    }

    // MARK: 分拣

    /// 分拣放进了别的画板：提示还没消失时，新放进的合进同一条，停留时间重新算
    func sortPlaced(_ written: [Placement]) {
        let earlier: [Placement] = if case .sorted(let earlier)? = notice?.undo { earlier } else { [] }
        let all = earlier + written
        let cards = Set(all.compactMap(\.cardID))
        let text = cards.count > 1 ? String(localized: "放进了 \(cards.count) 张")
            : String(localized: "放进了\(all.compactMap { p in boards.first { $0.id == p.boardID }.map { quoted($0.name) } }.formatted(.list(type: .and)))")
        post(Notice(text: text, undo: .sorted(all)))
        for board in Set(written.map(\.boardID)) { boardChanged(board) }
        reload()
    }

    /// 点了提示里的「撤销」
    func undoNotice() {
        guard let undo = notice?.undo else { return }
        notice = nil
        switch undo {
        case .sorted(let placements):
            perform { [self] in
                try await store?.removePlacements(placements.compactMap(\.id))
                for board in Set(placements.map(\.boardID)) { boardChanged(board) }
                reload()
            }
        case .trashed(let cards): restore(cards)
        case .taken(let placements):
            perform { [self] in
                try await store?.exchangePlacements(adding: placements, removing: [])
                await did(.placed(added: placements, removed: []), as: String(localized: "放回"), on: placements.first.map { .board($0.boardID) })
            }
        }
    }

    func setSorting(_ board: Board, autoSort: Bool, rule: String) {
        perform { [self] in
            try await store?.setSorting(board.id!, autoSort: autoSort, rule: rule)
            try await refreshBoards()
            sorter?.kick()
        }
    }

    /// 「未归类」里的「分拣这些卡」：只管没放进任何画板的卡
    func resortUnplaced() {
        perform { [self] in
            guard let count = try await store?.resortUnplaced() else { return }
            notify(count == 0 ? String(localized: "这里没有卡") : sortingUnavailable ?? (cloudReady ? String(localized: "交给分拣：\(count) 张") : String(localized: "完成云端模型设置后开始分拣")))
            sorter?.kick()
        }
    }

    /// 浏览器里点了「收进拼贴」：去收本机收件箱（扩展那边会告诉你收下了，这里收一张不另外提示）；扩展连上后，等浏览器的残缺卡自动补抓
    private func connectBrowsers(_ quickCollect: QuickCollect) {
        browserExtension.start { [weak self] in
            self?.collector.drainLocal(quick: quickCollect)
        } onConnect: { [weak self] in
            self?.collector.refetchForBrowser()
        }
    }

    /// 联网后，断网时收的残缺卡自动补抓，断网时理解失败的卡自动重试
    private func watchNetwork() {
        network.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if online, !self.online {
                    self.collector.refetchOffline()
                    self.retryFailed()
                    self.sorter?.kick()
                }
                self.online = online
            }
        }
        network.start(queue: .global(qos: .utility))
        collector.refetchOffline()
    }

    func refreshBoards() async throws {
        boards = try await store?.boards() ?? []
    }

    var title: String {
        switch location {
        case .board(let id): boards.first { $0.id == id }?.name ?? String(localized: "拼贴")
        case .collection(.all): String(localized: "全部卡片")
        case .collection(.unplaced): String(localized: "未归类")
        case .collection(.trash): String(localized: "废纸篓")
        case nil: String(localized: "拼贴")
        }
    }

    // MARK: 导航

    /// 从侧边栏换到另一处：后退记录清空
    func go(_ to: CanvasContent) {
        history = []
        show(to)
    }

    /// 双击画板入口进去
    func enter(_ board: Int64) {
        if let location { history.append(location) }
        show(.board(board))
    }

    func back() {
        guard let last = history.popLast() else { return }
        show(last)
    }

    private func show(_ to: CanvasContent) {
        // 离开画板时，分拣放进来的「新」角标消失
        if case .board(let left) = location, to != .board(left) { Task { try? await store?.clearUnseen(on: left) } }
        // 放大查看跟着地方走：离开时开着哪张记下来，切回来原样开着
        // 连着快切、上一次的新画面还没换上来时，开着的还是更早那个地方的卡，已经记过了，不记到这里
        if let here = location, detail == nil || detailHome == here { parked[here] = closing ? nil : detail.map { ($0, fromCanvas) } }
        location = to
        // 先看一眼，真换上来的时候才取走：连着快切被跳过的地方，记着的还留着
        let parkedHere = parked[to] != nil
        // 有放大查看（这边开着或那边要开）：画布不飞只淡；放大查看留到新画面画好，那一刻跟画布一起换，只有一个动作
        let still = detail != nil || parkedHere
        search.locationChanged()
        Task {
            try? await canvas?.show(to, still: still) { [self] in
                guard location == to else { return }
                // 卡已经不在这里就不开了
                let back = parked.removeValue(forKey: to).flatMap { canvas?.holds(card: $0.card) == true ? $0 : nil }
                // 压暗的底跟画布换内容同起同止。要关掉的：暗底挪进旧画面，跟它一起淡掉，外面的这一刻撤掉
                swapping = true
                Task { try? await Task.sleep(for: .seconds(Motion.swapSpan)); swapping = false }
                if detail != nil, back == nil { canvas?.shadeCurtain() }
                detail = back?.card
                guard let back else { return }
                (fromCanvas, stayed) = (back.fromCanvas, true)
                // 从画布打开的：画布上那份在换上来之前就拿起来，不会先露一下；关的时候缩回它
                if fromCanvas { spot = canvas?.spot(ofCard: back.card); lift(true) }
            }
            if case .board(let id) = to {
                try? await store?.markOpened(id)
            }
            await refreshCounts()
        }
    }

    /// 别处改了数据：画布和画板列表重读，当前画板的缩略拼贴重画
    func reload() { Task { await refresh() } }

    /// 改了资料库之后：搜索作废，画布、画板列表、状态栏重读，当前画板和这一步涉及的画板重画缩略拼贴；卡进了废纸篓，备好的灵感作废
    func refresh(after edit: Edit? = nil) async {
        searcher?.invalidate()
        var changed = edit?.boards ?? []
        if case .board(let id) = location { changed.insert(id) }
        for board in changed { boardChanged(board) }
        if case .trashed? = edit { await inspirer?.invalidate() }
        // 新写、改过的文字卡：按新内容重新理解
        switch edit {
        case .written?, .restored?: understander?.kick()
        default: break
        }
        try? await canvas?.reload()
        try? await refreshBoards()
        await refreshCounts()
        // 桌上的卡进了、出了废纸篓，收成了文字卡
        await discussions.refresh()
    }

    /// 做完一步：记进做这一步那处的撤销记录，再刷新
    private func did(_ edit: Edit, as name: String, on place: CanvasContent?) async {
        canvas?.record(edit, as: name, on: place)
        await refresh(after: edit)
    }

    /// 画板改了：停手 2 秒后在后台重画它的缩略拼贴，画好后刷新显示了它入口的画布
    private var collageWork: [Int64: Task<Void, Never>] = [:]

    func boardChanged(_ board: Int64) {
        collageWork[board]?.cancel()
        collageWork[board] = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let store = self?.store else { return }
            try? await BoardCollage.refresh(board, store: store)
            try? await self?.canvas?.reload()
        }
    }

    // MARK: 理解、模型

    private func refreshCounts() async {
        let board: Int64? = if case .board(let id) = location { id } else { nil }
        if let counts = try? await store?.counts(board: board) { self.counts = counts }
    }

    /// 理解每做完一张：一秒内最多刷新一次画布和状态栏
    private var progressPending = false

    private func understandingProgressed() {
        guard !progressPending else { return }
        progressPending = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            progressPending = false
            searcher?.invalidate()
            sorter?.kick()
            try? await canvas?.reload()
            await refreshCounts()
            refreshModelStates()
        }
    }

    private func refreshModelStates() {
        keyStates = Dictionary(uniqueKeysWithValues: cloud.map { ($0.name, $0.keyState) })
        cloudReady = cloudAPI?.isReady == true
        cloudFailure = cloudAPI?.lastFailure
        localModelReady = embedder?.isReady == true
    }

    /// 换服务商：带出上次给这家填的模型和地址
    func chooseVendor(_ vendor: Vendor) {
        var setup = CloudSetup.saved(for: vendor)
        setup.thinking = cloudSetup.thinking
        setCloud(setup)
    }

    /// 改云端怎么接。模型名在 OpenRouter 的模型列表里查不到时提示一句，不拦着：断网时也查不到；别家没有列表可查
    func setCloud(_ setup: CloudSetup) {
        guard setup != cloudSetup, let cloudAPI else { return }
        cloudSetup = setup
        setup.save()
        cloudAPI.configure(setup)
        refreshModelStates()
        // 换到能用的那家：等着的卡补上描述、开始分拣
        understander?.kick()
        sorter?.kick()
        cloudModelUnknown = false
        guard setup.vendor == .openRouter, !setup.model.isEmpty else { return }
        Task {
            let unknown = await cloudAPI.contextLength() == nil
            if cloudSetup == setup { cloudModelUnknown = unknown }
        }
    }

    /// 自动分拣为什么用不了；nil 表示能用。放不放进画板的线是按 Jev 报的概率定的，别的模型报的把握不能用同一条线比，
    /// 而只有 OpenRouter 转接 Jev
    var sortingUnavailable: String? {
        if cloudSetup.vendor != .openRouter { return String(localized: "自动分拣需使用 OpenRouter") }
        return cloudSetup.usesJev ? nil : String(localized: "自动分拣需使用默认的判断模型 Jev，清空判断模型即可恢复")
    }
    var keyRejected: Bool { keyStates.values.contains(.rejected) }

    func setKey(_ key: String, for provider: any Keyed) {
        perform { [self] in
            try provider.setKey(key)
            refreshModelStates()
            // 等待密钥的卡补上描述，等着的卡开始分拣
            understander?.kick()
            sorter?.kick()
        }
    }

    /// App 启动后空闲时加载本机模型：新装后第一次要约 6 秒，不能等到第一次搜索
    private func loadLocalModel() {
        guard let embedder, embedder.isReady else { return }
        Task.detached(priority: .utility) { try? embedder.load() }
    }

    func downloadLocalModel() {
        guard let store, modelDownload == nil else { return }
        modelDownload = 0
        perform { [self] in
            defer { modelDownload = nil }
            try await LocalModel.download(to: store.root) { p in Task { @MainActor [weak self] in if self?.modelDownload != nil { self?.modelDownload = p } } }
            refreshModelStates()
            loadLocalModel()
            understander?.kick()
        }
    }


    func retryFailed() {
        perform { [self] in
            try await store?.retryFailedUnderstanding()
            understander?.kick()
        }
    }

    /// 右键「重新理解」
    func reunderstand(_ items: [BoardItem]) {
        perform { [self] in
            try await store?.forgetUnderstanding(items.compactMap(\.placement.cardID))
            understander?.kick()
            reload()
        }
    }

    // MARK: 第一次打开的引导

    /// 这次要走的几步：没做过、也没提供过的
    private(set) var onboardingSteps: [OnboardingStep] = []
    /// 已经提供过的几步（走完或点了「以后再说」都算），以后不再出现
    private var offeredSteps: Set<String> = []
    static let offeredStepsKey = "onboardingSteps"
    /// 早先只记了看没看过引导，那时只有密钥和本机模型两步
    static let onboardedKey = "onboarded"

    private func prepareOnboarding(_ store: Store) async throws {
        offeredSteps = Set(try await store.setting(Self.offeredStepsKey, as: [String].self) ?? [])
        if try await store.setting(Self.onboardedKey, as: Bool.self) == true { offeredSteps.formUnion([OnboardingStep.keys, .model].map(\.rawValue)) }
        onboardingSteps = OnboardingStep.allCases.filter { step in
            let done = switch step {
            case .keys: cloudReady
            case .model: localModelReady
            case .browser: browserExtension.status != .absent
            case .phone: phoneInbox.received != nil
            }
            return !done && !offeredSteps.contains(step.rawValue)
        }
        showsOnboarding = !onboardingSteps.isEmpty
    }

    func finishOnboarding() {
        showsOnboarding = false
        offeredSteps.formUnion(onboardingSteps.map(\.rawValue))
        let offered = offeredSteps.sorted()
        Task { try? await store?.setSetting(Self.offeredStepsKey, offered) }
    }

    // MARK: Esc

    /// Esc 一层层退出：裁剪（不保留，回车才是确认） → 放大查看 → 选中（资料库里的，画板里的多张） → 灵感 → 搜索 → 后退到上一个画板
    @discardableResult
    func escape() -> Bool {
        if let canvas, canvas.isCropping { canvas.endCrop(commit: false); return true }
        if detail != nil { closeDetail(); return true }
        if canvas?.deselect() == true { return true }
        if search.escape() { return true }
        if !history.isEmpty { back(); return true }
        return false
    }

    /// 搜索框（SwiftUI 的输入框底下是 NSTextField，按占位文字认）
    private func searchFieldFocused(_ editor: NSText) -> Bool {
        guard let field = (editor as? NSTextView)?.delegate as? NSTextField else { return false }
        return field.placeholderString == SearchBar.placeholder || field.placeholderAttributedString?.string == SearchBar.placeholder
    }

    /// 最近一次拖动、滚动、缩放画布的时间：后台的本机模型在这之后半秒内让开显卡
    private let interaction = Interaction()

    private func installMonitors() {
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .leftMouseDragged]) { [interaction] event in
            interaction.touch()
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) || event.keyCode == 53 && event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
                  NSApp.modalWindow == nil, let self, let window = NSApp.keyWindow, window === self.canvas?.window else { return event }
            // 放大查看里左右键换卡。焦点在播放器里时左右键是它的快进快退，留给它
            if self.detail != nil, event.keyCode == 123 || event.keyCode == 124 {
                let inPlayer = sequence(first: window.firstResponder as? NSView, next: { $0?.superview }).contains { $0 is AVPlayerView || $0 is WKWebView }
                // 正在输入框里打字（搜索、讨论）：左右键是挪光标
                if inPlayer || (window.firstResponder as? NSTextView)?.isEditable == true { return event }
                self.step(event.keyCode == 123 ? -1 : 1)
                return nil
            }
            guard event.keyCode == 53 else { return event }
            // 在搜索框里按 Esc 也一层层退；别的输入框（重命名）留给它自己
            if let editor = window.firstResponder as? NSText, !self.searchFieldFocused(editor) { return event }
            // 拼音输入法还有没选的候选：Esc 留给输入法取消
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            return self.escape() ? nil : event
        }
    }

    // MARK: 画板

    /// 用选中的卡新建画板：卡放进去，人留在原处，接着给画板起名
    func newBoard(with items: [BoardItem], keepingHere: Bool = false) {
        perform { [self] in
            guard let board = try await store?.createBoard(String(localized: "未命名画板")) else { return }
            try await refreshBoards()
            put(items, into: board.id!, keepingHere: keepingHere)
            renaming = board
        }
    }

    func newBoard() {
        perform { [self] in
            guard let board = try await store?.createBoard(String(localized: "未命名画板")) else { return }
            try await refreshBoards()
            go(.board(board.id!))
            renaming = board
        }
    }

    func rename(_ board: Board, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        perform { [self] in
            try await store?.renameBoard(board.id!, to: name)
            reload()
        }
    }

    /// 删除画板：提示有几张卡不在别的画板里，选保留还是一起进废纸篓
    func delete(_ board: Board) {
        perform { [self] in
            guard let store, let id = board.id else { return }
            let orphans = try await store.cardsOnlyOn(id).count
            let alert = NSAlert()
            alert.messageText = String(localized: "删除画板「\(board.name)」？")
            alert.informativeText = orphans == 0
                ? String(localized: "画板里的卡都还在别的画板里，不受影响。别的画板里指向它的入口会一起移除。")
                : String(localized: "其中 \(orphans) 张卡不在任何别的画板里。别的画板里指向它的入口会一起移除。")
            alert.addButton(withTitle: orphans == 0 ? String(localized: "删除") : String(localized: "删除，卡片留在资料库"))
            if orphans > 0 { alert.addButton(withTitle: String(localized: "删除，卡片放进废纸篓")) }
            alert.addButton(withTitle: String(localized: "取消"))
            let response = alert.runModal()
            let cancel = orphans == 0 ? NSApplication.ModalResponse.alertSecondButtonReturn : .alertThirdButtonReturn
            guard response != cancel else { return }
            try await store.deleteBoard(id, trashingOrphans: response == .alertSecondButtonReturn && orphans > 0)
            try await refreshBoards()
            history.removeAll { $0 == .board(id) }
            canvas?.forgetUndoHistory(of: .board(id))
            if location == .board(id) { go(boards.first.map { .board($0.id!) } ?? .collection(.all)) } else { reload() }
        }
    }

    // MARK: 卡片

    /// 放进另一个画板：保留尺寸和裁剪，在那边现有卡片的下方排成一行。在画板里默认是移过去、从这里拿走；
    /// keepingHere（按住 ⌥ 拖、「也放进」）和在几种卡片视图里是放一份，这里不动。那边已经有的不再放一份；告诉你放到了哪里
    func put(_ items: [BoardItem], into target: Int64, keepingHere: Bool = false) {
        // 在等资料库之前定下是移还是放：等的时候可能已经换到别处
        let here = location, moves = canvas?.isEditable == true && !keepingHere, fromTrash = here == .collection(.trash)
        perform { [self] in
            guard let store else { return }
            let cards = items.filter { $0.placement.cardID != nil }
            // 从废纸篓拖来：先恢复（原来所在的画板也回来），再放进这个画板
            let restored = fromTrash ? cards.compactMap(\.placement.cardID) : []
            if fromTrash { try await store.restore(restored) }
            let existing = try await store.items(on: target)
            let already = Set(existing.compactMap(\.placement.cardID))
            let moving = cards.filter { !already.contains($0.placement.cardID!) }
            let name = boards.first { $0.id == target }?.name ?? String(localized: "画板")
            let skipped = cards.count - moving.count
            notify(fromTrash ? String(localized: "从废纸篓恢复，放进了「\(name)」")
                   : moving.isEmpty ? (cards.count == 1 ? String(localized: "这张本来就在「\(name)」里") : String(localized: "这几张本来就都在「\(name)」里"))
                   : (moves ? String(localized: "移到了「\(name)」") : keepingHere ? String(localized: "也放进了「\(name)」") : String(localized: "放进了「\(name)」")) + (skipped > 0 ? String(localized: "，其中 \(skipped) 张本来就在") : ""))
            if moving.isEmpty, !moves, !fromTrash { return }
            let frames = Layout.below(existing.map(\.placement.frame), sizes: moving.map(\.placement.frame.size))
            let added = try await store.place(zip(moving, frames).map { item, frame in
                var p = item.placement
                p.boardID = target
                p.frame = frame
                return p
            })
            record(.placed, added.compactMap(\.cardID), board: target)
            let removed = moves ? try await store.removePlacements(items.compactMap(\.placement.id)) : []
            // 恢复和放进画板算一步，⌘Z 一起撤回
            let placed = Edit.placed(added: added, removed: removed)
            canvas?.record(.restored(restored), placed, as: fromTrash ? String(localized: "移出废纸篓") : !removed.isEmpty ? String(localized: "移到画板") : keepingHere ? String(localized: "也放进画板") : String(localized: "放进画板"), on: here)
            await refresh(after: placed)
        }
    }

    /// 换你写的文字卡的底色；选中的里收进来的卡不受影响
    func tint(_ items: [BoardItem], _ tint: String?) {
        let here = location
        perform { [self] in
            guard let store else { return }
            let old = try await store.notes(items.compactMap(\.placement.cardID))
            let new = old.map { Note(card: $0.card, text: $0.text, tint: tint) }
            try await store.saveNotes(new)
            await did(.written(old: old, new: new), as: String(localized: "换颜色"), on: here)
        }
    }

    /// 放大查看里改了文字卡的字：和画布上写完走同一条路，⌘Z 撤得回
    func rewrite(_ card: Int64, to text: String) {
        let here = location
        perform { [self] in
            guard let store, let old = try await store.notes([card]).first, old.text != text else { return }
            let new = Note(card: card, text: text, tint: old.tint)
            try await store.saveNotes([new])
            await did(.written(old: [old], new: [new]), as: String(localized: "编辑文字"), on: here)
        }
    }

    /// 移出这个画板：只删摆放，卡片还在资料库里
    func removeFromBoard(_ items: [BoardItem]) {
        guard canvas?.isEditable == true, case .board(let board)? = location else { return }
        let here = location, name = boards.first { $0.id == board }?.name ?? String(localized: "画板")
        perform { [self] in
            guard let removed = try await store?.removePlacements(items.compactMap(\.placement.id)) else { return }
            let cards = removed.contains { $0.cardID != nil }
            post(Notice(text: String(localized: "移出了「\(name)」") + (cards ? String(localized: "，卡还在资料库里") : ""), undo: .taken(removed)))
            await did(.placed(added: [], removed: removed), as: String(localized: "移出画板"), on: here)
        }
    }

    /// 从资料库删除：放进废纸篓，不问。能撤回，所以不拦；眼前看不到的后果（别的画板里也没了）写在提示里，旁边就是「撤销」
    func trash(_ items: [BoardItem]) {
        let here = location
        perform { [self] in
            guard let store else { return }
            let cards = items.compactMap(\.placement.cardID)
            guard !cards.isEmpty else { return removeFromBoard(items) }
            let current: Int64? = if case .board(let id)? = here { id } else { nil }
            var names = Set<String>()
            for card in cards { for board in try await store.boards(containing: card) where board.id != current { names.insert(board.name) } }
            try await store.trash(cards)
            // 扔掉的卡不再出声
            if let playing = audio.track?.card, cards.contains(playing) { audio.stop() }
            let shown = names.sorted().prefix(3).map(quoted).formatted(.list(type: .and))
            post(Notice(text: String(localized: "放进了废纸篓") + (names.isEmpty ? "" : names.count > 3 ? String(localized: "，也移出了\(shown)等 \(names.count) 个画板") : String(localized: "，也移出了\(shown)")),
                        undo: .trashed(cards)))
            await did(.trashed(cards), as: String(localized: "放进废纸篓"), on: here)
        }
    }

    func restore(_ items: [BoardItem]) { restore(items.compactMap(\.placement.cardID)) }

    private func restore(_ cards: [Int64]) {
        let here = location
        perform { [self] in
            try await store?.restore(cards)
            await did(.restored(cards), as: String(localized: "恢复"), on: here)
        }
    }

    /// 废纸篓里选中的几张彻底删除
    func purge(_ items: [BoardItem]) {
        let cards = items.compactMap(\.placement.cardID)
        guard !cards.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = cards.count == 1 ? String(localized: "彻底删除这张卡？") : String(localized: "彻底删除这 \(cards.count) 张卡？")
        alert.informativeText = String(localized: "卡片和它们的文件会被删掉，不能恢复。")
        alert.addButton(withTitle: String(localized: "彻底删除"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { [self] in
            try await store?.purge(cards)
            // 彻底删了的卡撤销不回来：每一处的撤销记录都作废
            canvas?.forgetUndoHistory()
            reload()
        }
    }

    func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = String(localized: "清空废纸篓？")
        alert.informativeText = String(localized: "废纸篓里的卡和它们的文件会被彻底删除，不能恢复。")
        alert.addButton(withTitle: String(localized: "清空"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { [self] in
            try await store?.emptyTrash()
            // 彻底删了的卡撤销不回来：每一处的撤销记录都作废
            canvas?.forgetUndoHistory()
            reload()
        }
    }

    /// 把一个画板的入口放进当前画板
    func placeEntry(_ child: Int64, at point: CGPoint) {
        guard let here = location, case .board(let parent) = here else { return }
        perform { [self] in
            do {
                guard let entry = try await store?.placeEntry(child, on: parent, frame: Layout.spot(Layout.entrySize, near: point, avoiding: canvas?.occupied ?? [])) else { return }
                await did(.placed(added: [entry], removed: []), as: String(localized: "放入画板入口"), on: here)
            } catch Store.Failure.cycle {
                let alert = NSAlert()
                alert.messageText = String(localized: "不能放进来")
                alert.informativeText = parent == child ? String(localized: "画板不能放进它自己里面。") : String(localized: "这个画板里（或者更里面）已经有当前画板的入口，放进来会绕成一个圈。")
                alert.runModal()
            }
        }
    }

    /// 拖放里带的摆放编号换成眼前画布上的卡；画板入口不算
    func draggedItems(_ strings: [String]) -> [BoardItem]? {
        guard let text = strings.first, text.hasPrefix(CanvasView.placementsPrefix), let canvas else { return nil }
        let ids = text.dropFirst(CanvasView.placementsPrefix.count).split(separator: ",").compactMap { Int64($0) }
        let items = canvas.items(ids).filter { $0.placement.cardID != nil }
        return items.isEmpty ? nil : items
    }

    func draggedCards(_ strings: [String]) -> [Int64]? { draggedItems(strings)?.compactMap(\.placement.cardID) }

    fileprivate func bump() { canvasTick += 1 }

    /// 在后台做一件可能失败的事；失败了告诉你，不悄悄吞掉
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "没做成")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

// MARK: 画布交给外壳的事

extension AppModel: CanvasDelegate {
    func canvas(_ canvas: CanvasView, open item: BoardItem) {
        switch item.face {
        case .entry(let board, _, _): enter(board)
        case .card: open(item)
        }
    }

    /// 删除键：在画板里是移出这个画板，在资料库里才是放进废纸篓
    func canvas(_ canvas: CanvasView, delete items: [BoardItem]) {
        switch location {
        case .board?: removeFromBoard(items)
        case .collection(.trash)?, nil: break
        case .collection?: trash(items)
        }
    }

    /// ⌘C：卡记进剪贴板（见 Clip）。废纸篓里的不记；文字卡记全文，画布上只读了开头一段
    func canvas(_ canvas: CanvasView, copy items: [BoardItem]) {
        let cards = items.filter { $0.placement.cardID != nil }
        guard !cards.isEmpty, location != .collection(.trash) else { return }
        perform { [self] in
            guard let store else { return }
            let notes = try await store.notes(cards.filter(\.isNote).compactMap(\.placement.cardID))
            let texts = Dictionary(uniqueKeysWithValues: notes.map { ($0.card, $0.text) })
            let files = await Clip.export(Dictionary(uniqueKeysWithValues: cards.compactMap { item -> (Int64, Clip.Original)? in
                guard case .card(let face) = item.face, let file = face.original else { return nil }
                return (face.id, Clip.Original(title: face.title, file: store.files.url(of: file)))
            }))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(cards.map { Clip.item(for: $0, text: texts[$0.placement.cardID!], file: files[$0.placement.cardID!]) })
        }
    }

    /// 粘贴 ⌘C 记下的卡：同一张卡在这个画板再放一份，带着大小、裁剪和彼此的位置，整组摆在 point 附近。
    /// 已经在这里的、复制之后进了废纸篓的不放
    func paste(_ copied: [Placement], at point: CGPoint) {
        let here = location
        guard case .board(let board)? = here else { return notify(String(localized: "这几张已经在资料库里了，打开一个画板再粘贴")) }
        perform { [self] in
            guard let store else { return }
            let existing = try await store.items(on: board)
            let already = Set(existing.compactMap(\.placement.cardID))
            let live = try await store.live(copied.compactMap(\.cardID))
            let pasting = copied.filter { live.contains($0.cardID!) && !already.contains($0.cardID!) }
            let gone = copied.count { !live.contains($0.cardID!) }, there = copied.count - pasting.count - gone
            let skipped = [there > 0 ? String(localized: "\(there) 张本来就在这里") : nil, gone > 0 ? String(localized: "\(gone) 张已经不在资料库里") : nil].compactMap { $0 }
            if pasting.isEmpty, skipped.count == 1 {
                return notify(gone > 0 ? String(localized: "拷贝的卡已经不在资料库里了") : copied.count == 1 ? String(localized: "这张本来就在这个画板里") : String(localized: "这几张本来就都在这个画板里"))
            }
            if !skipped.isEmpty { notify(String(localized: "\(skipped.formatted(.list(type: .and)))，没再放")) }
            guard !pasting.isEmpty else { return }
            let frames = Layout.around(point, frames: pasting.map(\.frame), avoiding: existing.map(\.placement.frame))
            let added = try await store.place(zip(pasting, frames).map { p, frame in
                var p = p
                p.boardID = board
                p.frame = frame
                return p
            })
            record(.placed, added.compactMap(\.cardID), board: board)
            await did(.placed(added: added, removed: []), as: String(localized: "粘贴"), on: here)
            if location == here { canvas?.reveal(Set(added.compactMap(\.id))) }
        }
    }

    func canvas(_ canvas: CanvasView, accept pasteboard: NSPasteboard, at point: CGPoint) -> Bool {
        let copied = Clip.placements(in: pasteboard)
        if !copied.isEmpty {
            paste(copied, at: point)
            return true
        }
        if let text = pasteboard.string(forType: .string), text.hasPrefix(CanvasView.boardPrefix),
           let id = Int64(text.dropFirst(CanvasView.boardPrefix.count)) {
            placeEntry(id, at: point)
            return true
        }
        let sources = Collector.sources(in: pasteboard)
        collector.receive(sources, into: canvas.board, at: point)
        return !sources.isEmpty
    }

    func canvasStateChanged(_ canvas: CanvasView) {
        if canvas.isGathered, !canvas.selectedItems.isEmpty || canvas.isMovingCards { search.settle() }
        emptyHint = canvas.isEmpty ? Self.emptyHints[canvas.content] ?? String(localized: "拖进来、粘贴，或双击空白处写一张") : nil
        picked = canvas.browses ? canvas.selectedItems : []
        dragging = canvas.isDraggingOut
        leaving = canvas.isMovingCards && canvas.isEditable ? canvas.board : nil
        bump()
    }

    func canvas(_ canvas: CanvasView, didApply edit: Edit) async {
        // ⌘Z、⌘⇧Z 之后，提示里的「撤销」对不上了：收掉，免得再撤一次
        if notice?.undo != nil { notice = nil }
        await refresh(after: edit)
    }

    /// 点了音频卡上的播放钮：在播它就暂停，否则播它（别的那段停）
    func canvas(_ canvas: CanvasView, play item: BoardItem) {
        guard case .card(let face) = item.face, let store, let track = AudioPlayer.Track(face, files: store.files) else { return }
        audio.toggle(track)
    }

    func canvasDidEdit(_ canvas: CanvasView, error: Error?) {
        if let error {
            // 屏幕上挪过去了，资料库里没存上：告诉你，并重读回资料库里的样子
            perform { throw error }
            reload()
        } else if let board = canvas.board {
            boardChanged(board)
        }
    }

    func canvas(_ canvas: CanvasView, reveal card: Int64, on board: Int64) {
        go(.board(board))
        Task {
            // 等画板读完再对准
            for _ in 0..<40 where canvas.board != board || canvas.isGathered { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(100))
            canvas.focus(card: card)
        }
    }

    func canvasMenu(_ canvas: CanvasView, for items: [BoardItem]) -> NSMenu? {
        Menu.build(for: items, model: self)
    }

    /// 空着的时候说一句这里怎么会有东西；画板都用同一句
    private static let emptyHints: [CanvasContent?: String] = [
        .collection(.all): String(localized: "还没有卡。把图片、链接拖进画板，或在浏览器里右键「收进拼贴」"),
        .collection(.unplaced): String(localized: "都归进画板了"),
        .collection(.trash): String(localized: "废纸篓是空的"),
    ]
}

/// 画布上最近一次手势的时间，后台线程也能读
final class Interaction: Sendable {
    private let last = Mutex(Date.distantPast)
    func touch() { last.withLock { $0 = .now } }
    var isRecent: Bool { last.withLock { $0.timeIntervalSinceNow > -0.5 } }
}
