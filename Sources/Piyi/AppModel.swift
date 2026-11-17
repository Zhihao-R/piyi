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

/// State of the interface shell: the library, the board list, what's being viewed, back history, the layering of overlays
@MainActor @Observable
final class AppModel {
    private(set) var store: Store?
    private(set) var canvas: CanvasView?
    private(set) var boards: [Board] = []
    /// What the canvas is showing: a board, or All Cards / Unsorted / Trash
    private(set) var location: CanvasContent?
    /// When entering through a board entry, remember where we came from so Back returns there
    private(set) var history: [CanvasContent] = []
    /// The card in detail view
    var detail: Int64? {
        didSet {
            if let detail, detail != oldValue {
                noteOpened(detail)
                // Already looking at the result: a late cloud result no longer moves cards out from under your hand
                search.settle()
            }
            if detail != oldValue {
                // The panel being swapped out stays to finish fading on its own; one that has already shrunk back into its card needs no fade
                if let old = oldValue, closing { panels.removeAll { $0 == old } }
                if let detail { panels.removeAll { $0 == detail }; panels.append(detail) }
                // Card changed or closed: no longer tied to any card on the canvas, nor mid-close. Opening from the canvas has open record the origin afterwards
                (spot, closing, stayed) = (nil, false, false)
                detailHome = detail == nil ? nil : location
                if oldValue == nil { fromCanvas = false }
            }
            if focus?.card != detail { focus = nil }
        }
    }
    /// The one player for the whole app: sound doesn't follow the board or the detail view
    let audio = AudioPlayer()
    /// Incremented on every ⌘F; when the search bar sees it, it takes the cursor
    var searchFocus = 0
    /// One line of hint in the middle of the canvas when there are no cards in view
    private(set) var emptyHint: String?
    /// The passage the detail view should focus on: a citation clicked in the discussion scrolls to that passage and flashes it, video plays from that second
    var focus: Focus?

    struct Focus: Equatable {
        var card: Int64
        /// The passage's current text; nil means the whole card
        var text: String?
        var seconds: Int?
        /// Clicking the same spot again flashes it again
        let id = UUID()
    }
    /// The board being renamed
    var renaming: Board?
    /// Incremented when the selection changes or cropping starts/ends; menu items that depend on canvas state refresh on it
    private(set) var canvasTick = 0
    /// Cards deliberately selected in the library (a single click only views, it doesn't count). With a selection, the search bar at the bottom becomes the bar for acting on them;
    /// a click on a board that selects, or search results gathered in view, don't count
    private(set) var picked: [BoardItem] = []
    /// Dragging cards within this board: as soon as a drag starts, a "Remove from This Board" row appears above Trash in the sidebar, ready by the time the drag reaches the sidebar
    private(set) var leaving: Int64?
    /// Dragging cards out of the canvas: only then do the sidebar's boards and Trash accept drops and light up
    private(set) var dragging = false
    /// How the library is sorted: by default newest to oldest in one stretch, or grouped by day, color, or source. Remembered for next launch
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
    /// A temporary hint at the top of the window ("Already collected" and the like), gone after a few seconds
    private(set) var notice: Notice?
    /// The board whose sorting settings are being edited
    var sortSettings: Board?
    private(set) var collector: Collector!
    private let network = NWPathMonitor()
    private(set) var online = true

    // Model connection, understanding and sorting
    private(set) var understander: Understander?
    private(set) var sorter: Sorter?
    // Search and inspiration
    private(set) var searcher: Searcher?
    private(set) var inspirer: Inspirer?
    @ObservationIgnored private(set) lazy var search = SearchModel(model: self)
    // Discussion with AI
    private(set) var discussionKernel: DiscussionKernel?
    @ObservationIgnored private(set) lazy var discussions = DiscussionModel(model: self)
    private(set) var embedder: LocalEmbedder?
    /// Status bar: card counts for the current board and the library, processing, waiting for a key, failed
    private(set) var counts = Counts()
    /// Local model download progress 0–1; nil means not downloading
    private(set) var modelDownload: Double?
    /// Cloud providers that need a key; the settings page shows a key field for each
    private(set) var cloud: [any Keyed] = []
    /// Key status per provider and whether the local model is present: updated when a key is entered, the model finishes downloading, or understanding progresses (which may reveal a rejected key)
    private(set) var keyStates: [String: KeyState] = [:]
    /// How the cloud is connected: which provider, which model, whether to think during discussion
    private(set) var cloudSetup = CloudSetup.saved
    /// The newly chosen model wasn't found in OpenRouter's list
    private(set) var cloudModelUnknown = false
    /// The cloud is usable: the key is fine, and a custom provider's address and model are filled in
    private(set) var cloudReady = false
    /// Why the provider last rejected a request: model retired, not enabled, wrong address; the settings page says it under the model row
    private(set) var cloudFailure: String?
    @ObservationIgnored private var cloudAPI: Cloud?
    private(set) var localModelReady = false
    /// First-launch onboarding: enter a key, download the local model, install the browser extension, connect the phone
    var showsOnboarding = false
    let browserExtension = BrowserExtension()
    let phoneInbox = PhoneInbox()

    func start(quickCollect: QuickCollect) async {
        guard store == nil else { return }
        Writing.Part.restoreSaved()
        do {
            // The PIYI_ROOT environment variable points to another library directory (for trying a fresh install)
            let root = ProcessInfo.processInfo.environment["PIYI_ROOT"].map { URL(fileURLWithPath: $0) }
            let store = try Store(root: root ?? Store.defaultRoot)
            self.store = store
            let interaction = interaction
            let embedder = LocalEmbedder(file: LocalModel.file(in: store.root)) { interaction.isRecent }
            // In self-checks the OpenRouter key comes from an environment variable without touching the key file (same as the real cloud tests). This key is only for OpenRouter; other providers read their own as usual
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
            // Placeholder cards still extracting at last quit: those with a URL become incomplete cards and are refetched in the online check below; for the rest the original is still in the inbox and deduplication recognizes it on re-collect
            try await store.recoverUnfinished()
            // Block pages previously kept as normal cards: recognize them once (only once); those recognized likewise become incomplete cards and are refetched
            try await store.demoteChallengePagesOnce()
            collector.completeUnfinishedBodies()
            let canvas = CanvasView(store: store)
            canvas.delegate = self
            self.canvas = canvas
            audio.soundingChanged = { [weak self] in self?.canvas?.sounding = self?.audio.sounding }
            if let view = try? await store.setting(Self.libraryViewKey, as: LibraryView.self) { libraryView = view }
            // On first launch, stay on the sample board: it's created at the same moment as "My Board", so ordering by most recently opened can't tell which comes first.
            // For self-checks: PIYI_SAMPLE="board name" adds another copy of the sample board to the existing library and opens it, to see how the sample is laid out
            var landing: Int64?
            if try await store.boards().isEmpty { landing = try await firstLaunch(store) }
            else if let name = ProcessInfo.processInfo.environment["PIYI_SAMPLE"] { landing = try await addSample(store, named: name) }
            try await refreshBoards()
            try await closeSampleSortingOnce(store)
            if let id = landing ?? boards.first?.id { go(.board(id)) }
            discussions.reload()
            for board in boards where board.collage == nil { boardChanged(board.id!) }
            Task.detached(priority: .utility) { try? await store.completeThumbnails() }
            installMonitors()
            watchNetwork()
            // Shortcut, Services menu, browser extension and phone collections all go into the inbox first, only into the library, to be sorted automatically later;
            // hints are shown only after deduplication, with the same wording for every entry point (Receipt)
            connectBrowsers(quickCollect)
            await phoneInbox.start(store: store) { [weak self] inbox, heard in
                self?.collector.drain(inbox) { arrivals, receipt in
                    heard(arrivals, receipt)
                    self?.notify(receipt.text)
                }
            }
            quickCollect.start { [weak self] in self?.collector.drainLocal(quick: quickCollect) } tell: { [weak self] in self?.notify($0) }
            // Cards still queued at quit are processed and sorted this time
            understander?.kick()
            sorter?.kick()
            loadLocalModel()
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [embedder] _ in
                // Without releasing, llama.cpp crashes when the process exits
                embedder.unload()
            }
            try await prepareOnboarding(store)
            // For self-checks: PIYI_TRY="a sentence" types it and presses Return after launch, PIYI_TRY="✦" presses the inspiration button, PIYI_TRY="…a sentence" types without Return,
            // PIYI_TRY="💬a sentence" puts the first card on the board on the discussion table, then asks the sentence
            if let line = ProcessInfo.processInfo.environment["PIYI_TRY"] {
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

    /// First launch: create the "My Board" and "Sample" boards, return the sample board
    private func firstLaunch(_ store: Store) async throws -> Int64 {
        _ = try await store.createBoard(String(localized: "我的画板"))
        let sample = try await addSample(store, named: String(localized: "示例"))
        Seed.board = sample
        return sample
    }

    /// Build a sample board; the sample data goes through the normal collection flow and is placed at the positions in the manifest
    private func addSample(_ store: Store, named name: String) async throws -> Int64 {
        let sample = try await store.createBoard(name).id!
        // The sample cards' topics shouldn't pull your own things in; sample cards themselves aren't sorted into your boards either
        try await store.setSorting(sample, autoSort: false, rule: nil)
        try await refreshBoards()
        try await canvas?.show(.board(sample))
        let seed = Seed.sources()
        collector.collect(seed.map(\.source), into: sample, at: .zero, presets: seed.map(\.preset)) { [weak self] _ in
            Task { try? await store.markSorted(on: sample) }
            // When the board opened the sample cards weren't collected yet, so the camera framed an empty board: once collected, if the camera hasn't been moved, glide to the overview
            if let canvas = self?.canvas, canvas.board == sample, canvas.isAtPanorama { canvas.fitAll(animated: true) }
        }
        return sample
    }

    /// Existing libraries: turn off automatic sorting on the sample board once; after that, once you've opened it, leave it alone
    private func closeSampleSortingOnce(_ store: Store) async throws {
        guard !Seed.sortingClosed else { return }
        if let sample = boards.first(where: { $0.id == Seed.board }) { try await store.setSorting(sample.id!, autoSort: false, rule: sample.rule) }
        Seed.sortingClosed = true
        try await refreshBoards()
    }

    // MARK: Hints, network

    struct Notice: Identifiable, Equatable {
        /// A new one per update: when time's up, only dismiss one that hasn't been updated since
        let id = UUID()
        var text: String
        /// What clicking "Undo" reverts
        var undo: Undo?
    }

    enum Undo: Equatable {
        /// Placements added by sorting: remove them all; the cards still count as sorted
        case sorted([Placement])
        /// Cards just moved to Trash: restore
        case trashed([Int64])
        /// Placements just removed from a board: put them back where they were
        case taken([Placement])
    }

    func notify(_ text: String) { post(Notice(text: text)) }

    /// Open the card's original link or original file
    func follow(_ url: URL, of card: Int64) {
        NSWorkspace.shared.open(url)
        record(.followed, [card])
    }

    /// Record a revisit only after the detail view stays open for a full second: flipping through with the arrow keys doesn't count as "viewed again"
    private func noteOpened(_ card: Int64) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            if detail == card { record(.opened, [card]) }
        }
    }

    /// Which canvas card the detail view corresponds to right now: the one it was opened from on the canvas, and when closing, the one it shrinks back into. None when switched to with arrow keys or opened from the discussion bar
    private(set) var spot: Spot? {
        didSet { if let old = oldValue, old.placement != spot?.placement { canvas?.reveal(old) } }
    }
    /// The detail view was opened from the canvas: when closing, it shrinks back into that card on the canvas
    private var fromCanvas = false
    /// For each place left with the detail view open: which card was open and whether it was opened from the canvas
    private var parked: [CanvasContent: (card: Int64, fromCanvas: Bool)] = [:]
    /// The detail view is closing: it shrinks back into the card on the canvas and only really closes when done
    private(set) var closing = false
    /// Detail view panels on screen: the one being viewed, plus ones just swapped out that are still fading. Panels contain native text and player controls;
    /// removing a panel outright makes it vanish at once, so a swapped-out one keeps its original copy, fades on its own, then is removed
    private(set) var panels: [Int64] = []
    /// This one was left open when switching back to the board: no flying or growing, it fades in with the canvas
    private(set) var stayed = false
    /// Following the canvas as it changes content (switching boards): the dimmed backdrop brightens/darkens over the whole canvas change, starting and ending with it
    private(set) var swapping = false
    /// Which place the open card belongs to
    private var detailHome: CanvasContent?

    /// Open a card from the canvas: the detail view grows out of it
    func open(_ item: BoardItem) {
        guard let card = item.placement.cardID else { return }
        detail = card
        fromCanvas = true
        spot = canvas?.spot(item.id)
    }

    /// The detail view picks the card up and puts it back: while flying, the card on the canvas is hidden; when done, it's put back in place
    func lift(_ up: Bool) {
        guard let spot else { return }
        if up { canvas?.hide(spot) } else { canvas?.reveal(spot) }
    }

    /// Close the detail view: if opened from the canvas and the card is still in view, shrink back first; otherwise fade out directly
    func closeDetail() {
        guard let detail, !closing else { return }
        spot = fromCanvas ? spot.flatMap { canvas?.spot($0.placement) } ?? canvas?.spot(ofCard: detail) : nil
        if spot == nil { self.detail = nil } else { closing = true }
    }

    /// Shrinking back is done. If the card was changed on the way (arrow keys, clicking another card), don't close
    func finishClosing() {
        if closing { detail = nil }
    }

    /// A swapped-out panel finished fading
    func dismissed(_ card: Int64) {
        if card != detail { panels.removeAll { $0 == card } }
    }

    /// Left/right keys in the detail view: move to the previous/next card in the order on screen. Stop at either end
    func step(_ by: Int) {
        guard let detail, let next = canvas?.neighbor(of: detail, by: by) else { return }
        self.detail = next
    }

    /// "Fetch Again" clicked in the detail view: go back to the canvas to watch it re-extract
    func refetch(_ card: Int64) {
        detail = nil
        Task { if let full = try? await store?.card(card) { collector.refetch(full) } }
    }

    /// Record a revisit: written in the background; if it fails, don't bother you
    func record(_ revisit: Revisit, _ cards: [Int64], board: Int64? = nil) {
        guard let store else { return }
        Task { try? await store.record(revisit, cards, board: board) }
    }

    /// Hints with Undo stay longer so there's time to click
    private func post(_ new: Notice) {
        notice = new
        Task {
            try? await Task.sleep(for: .seconds(new.undo == nil ? Motion.notice : Motion.notice * 2))
            if notice?.id == new.id { notice = nil }
        }
    }

    // MARK: Sorting

    /// Sorting put cards into other boards: while the hint is still showing, new additions merge into the same hint and its timer restarts
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

    /// "Undo" in the hint was clicked
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

    /// "Sort These Cards" in "Unsorted": only handles cards not in any board
    func resortUnplaced() {
        perform { [self] in
            guard let count = try await store?.resortUnplaced() else { return }
            notify(count == 0 ? String(localized: "这里没有卡") : sortingUnavailable ?? (cloudReady ? String(localized: "交给分拣：\(count) 张") : String(localized: "完成云端模型设置后开始分拣")))
            sorter?.kick()
        }
    }

    /// "Collect to Piyi" clicked in the browser: collect from the local inbox (the extension tells you it was collected, so a single card gets no extra hint here); once the extension connects, auto-refetch incomplete cards waiting on the browser
    private func connectBrowsers(_ quickCollect: QuickCollect) {
        browserExtension.start { [weak self] in
            self?.collector.drainLocal(quick: quickCollect)
        } onConnect: { [weak self] in
            self?.collector.refetchForBrowser()
        }
    }

    /// Once online, auto-refetch incomplete cards collected while offline and auto-retry cards whose understanding failed while offline
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
        case .board(let id): boards.first { $0.id == id }?.name ?? String(localized: "片羽")
        case .collection(.all): String(localized: "全部卡片")
        case .collection(.unplaced): String(localized: "未归类")
        case .collection(.trash): String(localized: "废纸篓")
        case nil: String(localized: "片羽")
        }
    }

    // MARK: Navigation

    /// Switch to another place from the sidebar: back history is cleared
    func go(_ to: CanvasContent) {
        history = []
        show(to)
    }

    /// Double-click a board entry to enter it
    func enter(_ board: Int64) {
        if let location { history.append(location) }
        show(.board(board))
    }

    func back() {
        guard let last = history.popLast() else { return }
        show(last)
    }

    private func show(_ to: CanvasContent) {
        // When leaving a board, the "New" badges on cards added by sorting disappear
        if case .board(let left) = location, to != .board(left) { Task { try? await store?.clearUnseen(on: left) } }
        // The detail view follows the place: remember which card was open on leaving, reopen it as it was on returning
        // When switching quickly in a row and the previous new view hasn't come in yet, the open card is still from an even earlier place, already recorded; don't record it here
        if let here = location, detail == nil || detailHome == here { parked[here] = closing ? nil : detail.map { ($0, fromCanvas) } }
        location = to
        // Peek first, take it only when the view actually comes in: places skipped during quick switching keep what they remembered
        let parkedHere = parked[to] != nil
        // With a detail view (open here or about to open there): the canvas only fades, no flying; the detail view stays until the new view is drawn and swaps with the canvas at that moment, as a single motion
        let still = detail != nil || parkedHere
        search.locationChanged()
        Task {
            try? await canvas?.show(to, still: still) { [self] in
                guard location == to else { return }
                // Don't open if the card is no longer here
                let back = parked.removeValue(forKey: to).flatMap { canvas?.holds(card: $0.card) == true ? $0 : nil }
                // The dimmed backdrop starts and ends with the canvas change. If it's closing: move the backdrop into the old view so it fades with it, and remove the outer one now
                swapping = true
                Task { try? await Task.sleep(for: .seconds(Motion.swapSpan)); swapping = false }
                if detail != nil, back == nil { canvas?.shadeCurtain() }
                detail = back?.card
                guard let back else { return }
                (fromCanvas, stayed) = (back.fromCanvas, true)
                // Opened from the canvas: pick up the canvas copy before the new view comes in so it never flashes; shrink back into it when closing
                if fromCanvas { spot = canvas?.spot(ofCard: back.card); lift(true) }
            }
            if case .board(let id) = to {
                try? await store?.markOpened(id)
            }
            await refreshCounts()
        }
    }

    /// Data changed elsewhere: reload the canvas and the board list, redraw the current board's thumbnail collage
    func reload() { Task { await refresh() } }

    /// After changing the library: discard the search; reload canvas, board list, status bar; redraw thumbnail collages of the current board and boards touched by this step; if cards went to Trash, discard the prepared inspiration
    func refresh(after edit: Edit? = nil) async {
        searcher?.invalidate()
        var changed = edit?.boards ?? []
        if case .board(let id) = location { changed.insert(id) }
        for board in changed { boardChanged(board) }
        if case .trashed? = edit { await inspirer?.invalidate() }
        // Newly written or edited text cards: understand again from the new content
        switch edit {
        case .written?, .restored?: understander?.kick()
        default: break
        }
        try? await canvas?.reload()
        try? await refreshBoards()
        await refreshCounts()
        // Cards on the table went into or out of Trash, or were saved as text cards
        await discussions.refresh()
    }

    /// After a step: record it in the undo history of the place where it happened, then refresh
    private func did(_ edit: Edit, as name: String, on place: CanvasContent?) async {
        canvas?.record(edit, as: name, on: place)
        await refresh(after: edit)
    }

    /// A board changed: 2 seconds after editing stops, redraw its thumbnail collage in the background, then refresh canvases showing its entry
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

    // MARK: Understanding, models

    private func refreshCounts() async {
        let board: Int64? = if case .board(let id) = location { id } else { nil }
        if let counts = try? await store?.counts(board: board) { self.counts = counts }
    }

    /// Each time understanding finishes a card: refresh the canvas and status bar at most once a second
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

    /// Switch provider: bring back the model and address last entered for it
    func chooseVendor(_ vendor: Vendor) {
        var setup = CloudSetup.saved(for: vendor)
        setup.thinking = cloudSetup.thinking
        setCloud(setup)
    }

    /// Change how the cloud is connected. If the model name isn't in OpenRouter's model list, say so but don't block: it can't be found offline either; other providers have no list to check
    func setCloud(_ setup: CloudSetup) {
        guard setup != cloudSetup, let cloudAPI else { return }
        cloudSetup = setup
        setup.save()
        cloudAPI.configure(setup)
        refreshModelStates()
        // Switched to a usable provider: waiting cards get their descriptions and sorting starts
        understander?.kick()
        sorter?.kick()
        cloudModelUnknown = false
        guard setup.vendor == .openRouter, !setup.model.isEmpty else { return }
        Task {
            let unknown = await cloudAPI.contextLength() == nil
            if cloudSetup == setup { cloudModelUnknown = unknown }
        }
    }

    /// Why automatic sorting can't be used; nil means it can. The threshold for putting cards into a board is set by Jev's reported probabilities; other models' confidence can't be compared against the same threshold,
    /// and only OpenRouter relays Jev
    var sortingUnavailable: String? {
        if cloudSetup.vendor != .openRouter { return String(localized: "自动分拣需使用 OpenRouter") }
        return cloudSetup.usesJev ? nil : String(localized: "自动分拣需使用默认的判断模型 Jev，清空判断模型即可恢复")
    }
    var keyRejected: Bool { keyStates.values.contains(.rejected) }

    func setKey(_ key: String, for provider: any Keyed) {
        perform { [self] in
            try provider.setKey(key)
            refreshModelStates()
            // Cards waiting for a key get their descriptions, waiting cards start sorting
            understander?.kick()
            sorter?.kick()
        }
    }

    /// Load the local model when idle after launch: the first time after install takes about 6 seconds, can't wait for the first search
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

    /// Context menu "Read Again"
    func reunderstand(_ items: [BoardItem]) {
        perform { [self] in
            try await store?.forgetUnderstanding(items.compactMap(\.placement.cardID))
            understander?.kick()
            reload()
        }
    }

    // MARK: First-launch onboarding

    /// Steps to go through this time: those not done and not offered before
    private(set) var onboardingSteps: [OnboardingStep] = []
    /// Steps already offered (finished or "Not Now" both count); they don't appear again
    private var offeredSteps: Set<String> = []
    static let offeredStepsKey = "onboardingSteps"
    /// Earlier we only recorded whether onboarding had been seen; back then there were only two steps, key and local model
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

    /// Esc backs out layer by layer: crop (discarded; Return confirms) → detail view → selection (in the library, multiple in a board) → inspiration → search → back to the previous board
    @discardableResult
    func escape() -> Bool {
        if let canvas, canvas.isCropping { canvas.endCrop(commit: false); return true }
        if detail != nil { closeDetail(); return true }
        if canvas?.deselect() == true { return true }
        if search.escape() { return true }
        if !history.isEmpty { back(); return true }
        return false
    }

    /// The search field (SwiftUI's text field is an NSTextField underneath, recognized by its placeholder)
    private func searchFieldFocused(_ editor: NSText) -> Bool {
        guard let field = (editor as? NSTextView)?.delegate as? NSTextField else { return false }
        return field.placeholderString == SearchBar.placeholder || field.placeholderAttributedString?.string == SearchBar.placeholder
    }

    /// Last time the canvas was dragged, scrolled or zoomed: the background local model yields the GPU for half a second after that
    private let interaction = Interaction()

    private func installMonitors() {
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .leftMouseDragged]) { [interaction] event in
            interaction.touch()
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) || event.keyCode == 53 && event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
                  NSApp.modalWindow == nil, let self, let window = NSApp.keyWindow, window === self.canvas?.window else { return event }
            // Left/right switches cards in the detail view. When focus is in the player, left/right are its seek back/forward, leave them to it
            if self.detail != nil, event.keyCode == 123 || event.keyCode == 124 {
                let inPlayer = sequence(first: window.firstResponder as? NSView, next: { $0?.superview }).contains { $0 is AVPlayerView || $0 is WKWebView }
                // Typing in a text field (search, discussion): left/right move the cursor
                if inPlayer || (window.firstResponder as? NSTextView)?.isEditable == true { return event }
                self.step(event.keyCode == 123 ? -1 : 1)
                return nil
            }
            guard event.keyCode == 53 else { return event }
            // Esc in the search field also backs out layer by layer; other text fields (rename) handle it themselves
            if let editor = window.firstResponder as? NSText, !self.searchFieldFocused(editor) { return event }
            // Pinyin input method still has unchosen candidates: leave Esc to the input method to cancel
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            return self.escape() ? nil : event
        }
    }

    // MARK: Boards

    /// New board from the selected cards: the cards go in, you stay where you are, then name the board
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

    /// Delete a board: say how many cards aren't in any other board, choose to keep them or send them to Trash too
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

    // MARK: Cards

    /// Put into another board: keep size and crop, arranged in a row below that board's existing cards. In a board the default is to move, taking them from here;
    /// keepingHere (⌥-drag, "Also Add To") and the card-list views add a copy, leaving this one alone. Cards already there aren't added again; tell you where they went
    func put(_ items: [BoardItem], into target: Int64, keepingHere: Bool = false) {
        // Decide move vs. add before waiting on the library: by then we might have switched elsewhere
        let here = location, moves = canvas?.isEditable == true && !keepingHere, fromTrash = here == .collection(.trash)
        perform { [self] in
            guard let store else { return }
            let cards = items.filter { $0.placement.cardID != nil }
            // Dragged from Trash: restore first (the boards it was in come back too), then put into this board
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
            // Restoring and adding to a board are one step; ⌘Z undoes both together
            let placed = Edit.placed(added: added, removed: removed)
            canvas?.record(.restored(restored), placed, as: fromTrash ? String(localized: "移出废纸篓") : !removed.isEmpty ? String(localized: "移到画板") : keepingHere ? String(localized: "也放进画板") : String(localized: "放进画板"), on: here)
            await refresh(after: placed)
        }
    }

    /// Change the background color of text cards you wrote; collected cards in the selection are unaffected
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

    /// Text of a note edited in the detail view: same path as finishing writing on the canvas, undoable with ⌘Z
    func rewrite(_ card: Int64, to text: String) {
        let here = location
        perform { [self] in
            guard let store, let old = try await store.notes([card]).first, old.text != text else { return }
            let new = Note(card: card, text: text, tint: old.tint)
            try await store.saveNotes([new])
            await did(.written(old: [old], new: [new]), as: String(localized: "编辑文字"), on: here)
        }
    }

    /// Remove from this board: only delete the placement, the card stays in the library
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

    /// Delete from the library: move to Trash without asking. It's undoable, so no confirmation; consequences you can't see (gone from other boards too) are in the hint, right next to "Undo"
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
            // Trashed cards stop making sound
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

    /// Permanently delete the selected cards in Trash
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
            // Permanently deleted cards can't be undone: every place's undo history is invalidated
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
            // Permanently deleted cards can't be undone: every place's undo history is invalidated
            canvas?.forgetUndoHistory()
            reload()
        }
    }

    /// Put a board's entry into the current board
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

    /// Map placement IDs carried by a drag to cards on the current canvas; board entries don't count
    func draggedItems(_ strings: [String]) -> [BoardItem]? {
        guard let text = strings.first, text.hasPrefix(CanvasView.placementsPrefix), let canvas else { return nil }
        let ids = text.dropFirst(CanvasView.placementsPrefix.count).split(separator: ",").compactMap { Int64($0) }
        let items = canvas.items(ids).filter { $0.placement.cardID != nil }
        return items.isEmpty ? nil : items
    }

    func draggedCards(_ strings: [String]) -> [Int64]? { draggedItems(strings)?.compactMap(\.placement.cardID) }

    fileprivate func bump() { canvasTick += 1 }

    /// Do something that may fail in the background; if it fails, tell you instead of swallowing it silently
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

// MARK: Things the canvas hands to the shell

extension AppModel: CanvasDelegate {
    func canvas(_ canvas: CanvasView, open item: BoardItem) {
        switch item.face {
        case .entry(let board, _, _): enter(board)
        case .card: open(item)
        }
    }

    /// Delete key: in a board it removes from the board; only in the library does it move to Trash
    func canvas(_ canvas: CanvasView, delete items: [BoardItem]) {
        switch location {
        case .board?: removeFromBoard(items)
        case .collection(.trash)?, nil: break
        case .collection?: trash(items)
        }
    }

    /// ⌘C: put cards on the clipboard (see Clip). Not for cards in Trash; text cards copy their full text, the canvas only loaded the beginning
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

    /// Paste cards recorded by ⌘C: add the same cards again in this board, with their sizes, crops and relative positions, the whole group placed near point.
    /// Cards already here, or moved to Trash after copying, aren't pasted
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
        // After ⌘Z or ⌘⇧Z the "Undo" in the hint no longer matches: dismiss it so it can't undo twice
        if notice?.undo != nil { notice = nil }
        await refresh(after: edit)
    }

    /// Play button on an audio card clicked: pause if it's playing, otherwise play it (stopping the other one)
    func canvas(_ canvas: CanvasView, play item: BoardItem) {
        guard case .card(let face) = item.face, let store, let track = AudioPlayer.Track(face, files: store.files) else { return }
        audio.toggle(track)
    }

    func canvasDidEdit(_ canvas: CanvasView, error: Error?) {
        if let error {
            // Moved on screen but not saved to the library: tell you, and reload to what the library holds
            perform { throw error }
            reload()
        } else if let board = canvas.board {
            boardChanged(board)
        }
    }

    func canvas(_ canvas: CanvasView, reveal card: Int64, on board: Int64) {
        go(.board(board))
        Task {
            // Wait for the board to load before focusing
            for _ in 0..<40 where canvas.board != board || canvas.isGathered { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(100))
            canvas.focus(card: card)
        }
    }

    func canvasMenu(_ canvas: CanvasView, for items: [BoardItem]) -> NSMenu? {
        Menu.build(for: items, model: self)
    }

    /// When empty, say how things would get here; all boards use the same sentence
    private static let emptyHints: [CanvasContent?: String] = [
        .collection(.all): String(localized: "还没有卡。把图片、链接拖进画板，或在浏览器里右键「收进片羽」"),
        .collection(.unplaced): String(localized: "都归进画板了"),
        .collection(.trash): String(localized: "废纸篓是空的"),
    ]
}

/// Time of the most recent gesture on the canvas, readable from background threads too
final class Interaction: Sendable {
    private let last = Mutex(Date.distantPast)
    func touch() { last.withLock { $0 = .now } }
    var isRecent: Bool { last.withLock { $0.timeIntervalSinceNow > -0.5 } }
}
