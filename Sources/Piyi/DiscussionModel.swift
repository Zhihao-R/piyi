import AppKit
import Observation
import Library
import Intelligence

/// 讨论栏和侧边栏讨论组的状态。讨论记录在资料库里，这里只是眼前这一段的读数和正在生成的那段字；
/// 讨论内核跑在后台，换到别的讨论时照样跑完，答完了侧边栏那一行亮一个点
@MainActor @Observable
final class DiscussionModel {
    /// 讨论栏展开
    var isOpen = false { didSet { if isOpen, !oldValue { reload() } } }
    /// 讨论栏里的讨论；nil 是草稿：还没发第一句，不进侧边栏
    private(set) var current: Int64?
    private(set) var name = String(localized: "新讨论")
    private(set) var desk: [Card] = []
    private(set) var events: [DiscussionEvent] = []
    /// 桌上这几张卡之前的讨论：还没说话时列在空白处
    private(set) var earlier: [DiscussionSummary] = []
    /// 侧边栏的讨论组，最近有动静的在前
    private(set) var all: [DiscussionSummary] = []
    /// 找卡的候选卡、引用的卡：卡名
    private(set) var titles: [Int64: String] = [:]
    /// 正在跑的讨论和它们生成到一半的回答（只在内存里：停下就算没答完）
    private(set) var writing: [Int64: String] = [:]
    private var running: [Int64: Task<Void, Never>] = [:]
    /// 发给模型的内容超过了上限的讨论
    private(set) var tooLong: Set<Int64> = []
    /// 正在重命名的讨论
    var renaming: DiscussionSummary?
    /// 点了桌上的「+」：输入框里起一个 @ 挑卡
    var picking = false
    /// 草稿桌上的卡
    private var draft: [Int64] = []

    private unowned let model: AppModel
    private var store: Store? { model.store }
    private var kernel: DiscussionKernel? { model.discussionKernel }

    init(model: AppModel) { self.model = model }

    var isRunning: Bool { current.map { running[$0] != nil } ?? false }
    var isTooLong: Bool { current.map(tooLong.contains) ?? false }
    /// 有问题没答完、也没在跑：显示「没答完」和重试
    var isUnfinished: Bool { !isRunning && DiscussionKernel.isUnfinished(events) }
    /// 收起时有新回答：工具栏按钮上亮一个点
    var hasUnread: Bool { all.contains { $0.unread && !(isOpen && $0.id == current) } }

    /// 写死的几句建议问题，不调模型；只在还没开口时给，聊起来以后不再插话
    var suggestions: [String] {
        guard events.isEmpty else { return [] }
        let live = desk.filter { $0.trashedAt == nil }.count
        return live == 1 ? [String(localized: "用三句话讲讲"), String(localized: "我还收过类似的吗")] : live > 1 ? [String(localized: "这几张说法一致吗")] : []
    }

    func onDesk(_ card: Int64) -> Bool { desk.contains { $0.id == card } }

    // MARK: 入口

    /// 入口上的叫法：讨论栏收起时是「讨论」，展开时是「引用」，都已引用是「已引用」（灰的）。界面上不说「桌」，用户不懂。
    /// 放大查看的玻璃按钮、操作条、右键菜单都从这里取
    func entry(for cards: [Int64]) -> (title: String, enabled: Bool) {
        guard isOpen else { return (String(localized: "讨论"), true) }
        return cards.allSatisfy(onDesk) ? (String(localized: "已引用"), false) : (String(localized: "引用"), true)
    }

    /// 讨论栏收起时开一段新讨论，展开时放上当前的桌
    func discuss(_ cards: [Int64]) {
        if !isOpen {
            newDiscussion()
            isOpen = true
        }
        place(cards)
    }

    /// 放上讨论栏里的桌
    func place(_ cards: [Int64]) {
        let target = current
        Task {
            await put(cards, on: target)
            await refresh()
        }
    }

    /// 拖到侧边栏某一段讨论上：讨论栏不切换，顶部提示一句
    func place(_ cards: [Int64], onto discussion: DiscussionSummary) {
        let name = discussion.discussion.displayName
        Task {
            guard let placed = await put(cards, on: discussion.id) else { return }
            model.notify(placed.isEmpty ? String(localized: "「\(name)」已经引用了这张") : String(localized: "已引用到「\(name)」"))
            await refresh()
        }
    }

    /// 放上桌的唯一一条路（nil 是草稿桌）：桌上已有的跳过；放不下（超过模型上下文的一半）就都不放，返回 nil
    @discardableResult
    private func put(_ cards: [Int64], on discussion: Int64?) async -> [Int64]? {
        guard let store, let kernel else { return nil }
        var desk: [Card] = []
        if let discussion { desk = (try? await store.desk(of: discussion)) ?? [] } else {
            for id in draft { if let card = try? await store.card(id) { desk.append(card) } }
        }
        var fresh: [Card] = []
        for id in Set(cards).subtracting(desk.compactMap(\.id)) { if let card = try? await store.card(id) { fresh.append(card) } }
        guard !fresh.isEmpty else { return [] }
        guard await kernel.fits(desk + fresh) else {
            model.notify(String(localized: "引用的卡太多了，先取消几张"))
            return nil
        }
        let ids = fresh.compactMap(\.id)
        if let discussion { _ = try? await store.placeOnDesk(ids, of: discussion) } else { draft += ids }
        model.record(.discussed, ids)
        return ids
    }

    func takeOff(_ card: Int64) {
        guard let store else { return }
        Task {
            if let current { try? await store.takeOffDesk(card, of: current) } else { draft.removeAll { $0 == card } }
            await refresh()
        }
    }

    /// 搜索提问的「接着聊」：依据的卡放上桌，问题和回答原样成为开头，不再答一遍。
    /// 搜索只读了简介，说不出哪句话出自哪张卡：引用只记整张卡，不往回答里插小数字
    func continueFromSearch(question: String, answer: String, cards: [Int64]) {
        guard let store else { return }
        Task {
            var citations: [Citation] = []
            for id in cards { if let card = try? await store.card(id) { citations.append(Citation(ref: "c\(id)", card: id, quote: card.displayTitle)) } }
            guard let id = try? await store.startDiscussion(desk: cards, opening: [.question(question), .answer(Answer(text: answer, citations: citations))]) else { return }
            model.record(.discussed, cards)
            open(id)
        }
    }

    func newDiscussion() {
        current = nil
        draft = []
        reload()
    }

    /// 太长了：带着桌上的卡开一段新讨论
    func startOver() {
        draft = desk.compactMap(\.id)
        current = nil
        reload()
    }

    func open(_ discussion: Int64) {
        current = discussion
        isOpen = true
        reload()
    }

    // MARK: 说话

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store else { return }
        let target = current
        Task {
            do {
                // 发到发问那一刻看着的讨论：等写入的工夫换到别处也不跑错
                let id: Int64
                if let target {
                    try await store.append([.question(text)], to: target)
                    id = target
                } else {
                    id = try await store.startDiscussion(desk: draft, opening: [.question(text)])
                    draft = []
                    if current == nil { current = id }
                }
                run(id)
                await refresh()
            } catch {
                model.notify(String(localized: "没发出去：\(error.localizedDescription)"))
            }
        }
    }

    /// 停止：断开这次调用，这个问题算没答完
    func stop() {
        guard let current else { return }
        running[current]?.cancel()
    }

    func retry() {
        guard let current else { return }
        run(current)
    }

    private func run(_ discussion: Int64) {
        guard let kernel, running[discussion] == nil else { return }
        tooLong.remove(discussion)
        writing[discussion] = ""
        running[discussion] = Task {
            do {
                try await kernel.run(discussion) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.running[discussion] != nil else { return }
                        switch progress {
                        case .writing(let text): self.writing[discussion] = text
                        case .recorded:
                            // 记下了一条（工具结果、回答）：生成中的字作废，从记录重读
                            self.writing[discussion] = ""
                            await self.refresh()
                        }
                    }
                }
            } catch is DiscussionKernel.TooLong {
                tooLong.insert(discussion)
            } catch where Task.isCancelled || error is CancellationError {
            } catch {
                model.notify(String(localized: "没答完：\(error.localizedDescription)"))
            }
            running[discussion] = nil
            writing[discussion] = nil
            await refresh()
            // 答完就能接着问；名字起好了再刷新一次
            await kernel.nameIfNeeded(discussion)
            await refresh()
        }
    }

    // MARK: 回答

    /// 收成文字卡：去掉引用小数字，放进当前画板；不在画板里时进资料库
    func collect(_ answer: Answer) {
        let text = Citations.plain(answer.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if model.canvas?.addNote(text, as: String(localized: "收成文字卡")) == nil {
            Task {
                guard (try? await store?.createNote(text)) != nil else { return }
                model.notify(String(localized: "收成了一张文字卡，在资料库里"))
                model.reload()
            }
        }
    }

    func copy(_ answer: Answer) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Citations.plain(answer.text).trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
    }

    /// 点了引用：在画布上打开这张卡的放大查看，滚到那一段并闪一下，视频从那一秒播；讨论栏不动
    func open(_ citation: Citation) {
        guard let id = citation.card, let store else { return }
        Task {
            guard let card = try? await store.card(id) else { return model.notify(String(localized: "这张卡已经删了")) }
            var focus = AppModel.Focus(card: id, text: nil, seconds: citation.seconds)
            if let part = citation.part {
                if let passage = Passages.find(citation.quote, part: part, in: card) {
                    (focus.text, focus.seconds) = (passage.text, passage.seconds ?? citation.seconds)
                } else {
                    model.notify(String(localized: "原文改过了"))
                }
            }
            model.focus = focus
            model.detail = id
        }
    }

    // MARK: 侧边栏

    func rename(_ discussion: DiscussionSummary, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let store else { return }
        Task {
            try? await store.renameDiscussion(discussion.id, to: name)
            await refresh()
        }
    }

    /// 删除讨论：不能撤回，所以问一句
    func delete(_ discussion: DiscussionSummary) {
        let alert = NSAlert()
        alert.messageText = String(localized: "删除讨论「\(discussion.discussion.displayName)」？")
        alert.informativeText = String(localized: "讨论记录会被删掉，不能恢复。引用的卡还在资料库里。")
        alert.addButton(withTitle: String(localized: "删除"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn, let store else { return }
        running[discussion.id]?.cancel()
        Task {
            try? await store.deleteDiscussion(discussion.id)
            if current == discussion.id { current = nil }
            await refresh()
        }
    }

    // MARK: 读

    func reload() { Task { await refresh() } }

    /// 从资料库重读眼前这段讨论和侧边栏的列表；讨论栏开着就算看过了。
    /// 读的工夫换到了别的讨论：这次读的不算，免得显示成另一段的
    func refresh() async {
        guard let store else { return }
        let current = current, draft = draft
        var (name, desk, events) = (String(localized: "新讨论"), [Card](), [DiscussionEvent]())
        if let current {
            name = (try? await store.discussion(current))??.displayName ?? name
            desk = (try? await store.desk(of: current)) ?? []
            events = (try? await store.events(of: current)) ?? []
        } else {
            for id in draft { if let card = try? await store.card(id) { desk.append(card) } }
        }
        let earlier = events.isEmpty ? ((try? await store.discussions(about: desk.compactMap(\.id))) ?? []) : []
        let all = (try? await store.discussions()) ?? []
        guard self.current == current else { return }
        (self.name, self.desk, self.events, self.earlier) = (name, desk, events, earlier)
        if isOpen, let current, let last = events.last {
            try? await store.markSeen(current, through: last.seq)
            self.all = (try? await store.discussions()) ?? all
        } else {
            self.all = all
        }
        await loadTitles(store)
    }

    /// 候选卡和引用的卡的卡名
    private func loadTitles(_ store: Store) async {
        var ids = Set<Int64>()
        for event in events {
            switch event.what {
            case .result(let r): if case .cards(let cards)? = r.shown { ids.formUnion(cards) }
            case .answer(let a): ids.formUnion(a.citations.compactMap(\.card))
            default: break
            }
        }
        for card in desk { titles[card.id!] = card.displayTitle }
        for id in ids where titles[id] == nil {
            if let card = try? await store.card(id) { titles[id] = card.displayTitle }
        }
    }

    /// @ 挑卡：按字找用搜索框同一套字面匹配；还没打字时列最近收的
    func cards(matching text: String) async -> [Card] {
        guard let store else { return [] }
        guard !text.isEmpty, let searcher = model.searcher else { return (try? await store.recentCards(limit: Self.picks)) ?? [] }
        var q = Query(text: text)
        q.lookFor(text)
        var cards: [Card] = []
        for id in await searcher.literal(q).prefix(Self.picks) { if let card = try? await store.card(id) { cards.append(card) } }
        return cards
    }

    /// @ 挑卡最多列几张
    static let picks = 6
}
