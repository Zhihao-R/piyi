import AppKit
import Observation
import Library
import Intelligence

/// State of the discussion bar and the sidebar's discussion group. Discussion records live in the library; this holds only the readout of the current one and the text being generated;
/// the discussion engine runs in the background and finishes even after switching to another discussion; when done, a dot lights up on its sidebar row
@MainActor @Observable
final class DiscussionModel {
    /// Discussion bar expanded
    var isOpen = false { didSet { if isOpen, !oldValue { reload() } } }
    /// The discussion in the discussion bar; nil is a draft: no first message sent yet, not in the sidebar
    private(set) var current: Int64?
    private(set) var name = String(localized: "新讨论")
    private(set) var desk: [Card] = []
    private(set) var events: [DiscussionEvent] = []
    /// Earlier discussions about the cards on the table: listed in the blank space before anything is said
    private(set) var earlier: [DiscussionSummary] = []
    /// The sidebar's discussion group, most recently active first
    private(set) var all: [DiscussionSummary] = []
    /// Candidate cards when looking for cards, cited cards: card names
    private(set) var titles: [Int64: String] = [:]
    /// Running discussions and their half-generated answers (in memory only: stopping counts as unfinished)
    private(set) var writing: [Int64: String] = [:]
    private var running: [Int64: Task<Void, Never>] = [:]
    /// Discussions whose content sent to the model exceeded the limit
    private(set) var tooLong: Set<Int64> = []
    /// The discussion being renamed
    var renaming: DiscussionSummary?
    /// "+" on the table clicked: start an @ card pick in the input field
    var picking = false
    /// Cards on the draft table
    private var draft: [Int64] = []

    private unowned let model: AppModel
    private var store: Store? { model.store }
    private var kernel: DiscussionKernel? { model.discussionKernel }

    init(model: AppModel) { self.model = model }

    var isRunning: Bool { current.map { running[$0] != nil } ?? false }
    var isTooLong: Bool { current.map(tooLong.contains) ?? false }
    /// A question left unanswered and not running: show "Answer didn’t finish" and retry
    var isUnfinished: Bool { !isRunning && DiscussionKernel.isUnfinished(events) }
    /// A new answer arrived while collapsed: a dot lights up on the toolbar button
    var hasUnread: Bool { all.contains { $0.unread && !(isOpen && $0.id == current) } }

    /// A few hard-coded suggested questions, no model call; offered only before anything is said, no interjecting once the conversation starts
    var suggestions: [String] {
        guard events.isEmpty else { return [] }
        let live = desk.filter { $0.trashedAt == nil }.count
        return live == 1 ? [String(localized: "用三句话讲讲"), String(localized: "我还收过类似的吗")] : live > 1 ? [String(localized: "这几张说法一致吗")] : []
    }

    func onDesk(_ card: Int64) -> Bool { desk.contains { $0.id == card } }

    // MARK: Entry points

    /// The label on entry points: "Discuss" when the discussion bar is collapsed, "Cite" when expanded, "Cited" (gray) when all are cited. The UI never says "table"; users wouldn't get it.
    /// The detail view's glass buttons, the action bar and the context menu all take it from here
    func entry(for cards: [Int64]) -> (title: String, enabled: Bool) {
        guard isOpen else { return (String(localized: "讨论"), true) }
        return cards.allSatisfy(onDesk) ? (String(localized: "已引用"), false) : (String(localized: "引用"), true)
    }

    /// With the discussion bar collapsed, start a new discussion; when expanded, put on the current table
    func discuss(_ cards: [Int64]) {
        if !isOpen {
            newDiscussion()
            isOpen = true
        }
        place(cards)
    }

    /// Put on the table in the discussion bar
    func place(_ cards: [Int64]) {
        let target = current
        Task {
            await put(cards, on: target)
            await refresh()
        }
    }

    /// Dragged onto a discussion in the sidebar: the discussion bar doesn't switch, a hint shows at the top
    func place(_ cards: [Int64], onto discussion: DiscussionSummary) {
        let name = discussion.discussion.displayName
        Task {
            guard let placed = await put(cards, on: discussion.id) else { return }
            model.notify(placed.isEmpty ? String(localized: "「\(name)」已经引用了这张") : String(localized: "已引用到「\(name)」"))
            await refresh()
        }
    }

    /// The only way onto the table (nil is the draft table): cards already there are skipped; if they don't fit (over half the model's context), add none and return nil
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

    /// "Continue in Discussion" from a search question: the supporting cards go on the table, the question and answer become the opening as is, not answered again.
    /// Search read only the descriptions and can't tell which sentence came from which card: citations record whole cards only, no small numbers inserted into the answer
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

    /// Too long: start a new discussion with the cards on the table
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

    // MARK: Speaking

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store else { return }
        let target = current
        Task {
            do {
                // Send to the discussion being viewed at the moment of asking: switching elsewhere while it's written doesn't misroute it
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

    /// Stop: cut off this call; the question counts as unfinished
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
                            // An entry was recorded (tool result, answer): discard the text being generated and reread from the record
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
            // Once answered you can ask again; refresh once more after the name is set
            await kernel.nameIfNeeded(discussion)
            await refresh()
        }
    }

    // MARK: Answers

    /// Save as a note: remove the small citation numbers and put it in the current board; into the library when not in a board
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

    /// Citation clicked: open this card's detail view on the canvas, scroll to that passage and flash it, video plays from that second; the discussion bar stays
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

    // MARK: Sidebar

    func rename(_ discussion: DiscussionSummary, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let store else { return }
        Task {
            try? await store.renameDiscussion(discussion.id, to: name)
            await refresh()
        }
    }

    /// Delete a discussion: can't be undone, so ask
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

    // MARK: Reading

    func reload() { Task { await refresh() } }

    /// Reread the current discussion and the sidebar list from the library; with the discussion bar open it counts as seen.
    /// If another discussion was switched to while reading: discard this read so it isn't shown as the other one
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

    /// Card names of candidate cards and cited cards
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

    /// @ card pick: finding by text uses the same literal matching as the search field; before typing, list the most recently collected
    func cards(matching text: String) async -> [Card] {
        guard let store else { return [] }
        guard !text.isEmpty, let searcher = model.searcher else { return (try? await store.recentCards(limit: Self.picks)) ?? [] }
        var q = Query(text: text)
        q.lookFor(text)
        var cards: [Card] = []
        for id in await searcher.literal(q).prefix(Self.picks) { if let card = try? await store.card(id) { cards.append(card) } }
        return cards
    }

    /// The most cards an @ card pick lists
    static let picks = 6
}
