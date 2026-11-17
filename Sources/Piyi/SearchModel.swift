import AppKit
import Observation
import Library
import Intelligence
import Canvas
import Tokens

/// State of the search bar and the text panel. A sentence first gets instant feedback from keyword rules (literally matching cards light up in place);
/// on Return, local results gather in view at once, replaced only if the cloud understanding and ranking come back with a different set; text for inspiration, card draws and questions shows in the text panel
@MainActor @Observable
final class SearchModel {
    var text = "" { didSet { if text != oldValue { typed() } } }
    /// Conditions chosen with filter buttons; conditions parsed from the sentence are separate, the two merge into one query
    var filters = Filters() { didSet { if filters != oldValue { typed() } } }
    /// Conditions in effect: parsed by rules while typing, replaced by the model's understanding after Return. Shown on the filter buttons
    private(set) var parsed = Query(text: "")
    /// Waiting for the model (understanding the sentence, re-ranking, writing inspiration). Also counts when local results are gathered but the cloud hasn't returned: the result isn't fully settled
    private(set) var working = false
    /// Text panel: inspiration's wording, a card draw's interpretation, a question's answer
    private(set) var panel: Panel?
    /// What kind of result is gathered in view; nil means not gathering
    private(set) var showing: Intent?
    /// How many gathered cards come from other boards and haven't been kept yet
    private(set) var visitors = 0

    struct Panel: Equatable {
        enum Kind { case inspire, draw, ask }
        var kind: Kind
        /// nil means still writing
        var text: String?
        /// Cards a question's answer is based on: "Continue in Discussion" puts them on the table
        var cards: [Int64] = []
        /// The question asked
        var question = ""
    }

    private unowned let model: AppModel
    private var searcher: Searcher? { model.searcher }
    /// A request ID: when the user types again or presses again, results from old requests are discarded so the view doesn't flicker back and forth
    private var request = 0
    private var literalWork: Task<Void, Never>?
    /// Once typing stops, hand the sentence to the model to understand first; by Return it's usually back
    private var early: (text: String, filters: Filters, task: Task<Query, Never>)?
    /// The request whose understanding has come back: Return uses it directly without searching by rules first
    private var understood: (task: Task<Query, Never>, query: Query)?
    /// The request whose local results are gathered and that's still waiting for the cloud
    private var unsettled: Int?

    init(model: AppModel) { self.model = model }

    /// The current board; nil in the card-list views
    var currentBoard: Int64? { if case .board(let id) = model.location { id } else { nil } }

    /// Whether the model is usable: online, cloud settings complete
    var modelReady: Bool { model.online && model.cloudReady }

    /// Why the inspiration button can't be used; nil means it can
    var inspirationBlocked: String? {
        if !model.online { return String(localized: "离线时用不了灵感：要模型来说出卡片之间的联系") }
        if !model.cloudReady { return model.keyRejected ? String(localized: "密钥无效，更换后才能用灵感") : String(localized: "完成云端模型设置后才能用灵感") }
        return nil
    }

    // MARK: Typing

    private func typed() {
        // Typing again while still waiting for the model: old results being generated are discarded and won't change the view when they arrive
        if working { cancel() }
        let rules = QueryRules.parse(text, filters: filters)
        parsed = rules
        literalWork?.cancel()
        literalWork = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let searcher else { return }
            let hits = rules.tokens.isEmpty ? [] : await searcher.literal(rules)
            guard !Task.isCancelled else { return }
            // When matches go from some to none, wait a bit before dimming: a character or two not matching mid-typing doesn't make the view flicker
            if hits.isEmpty, model.canvas?.isSpotlit == true {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            model.canvas?.spotlight(Set(hits))
            // Typing stopped for 0.6 seconds: hand it to the model to understand early
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            prefetch()
        }
    }

    private func prefetch() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let searcher, !trimmed.isEmpty else { early = nil; return }
        guard early?.text != trimmed || early?.filters != filters else { return }
        let (filters, online) = (filters, model.online)
        let task = Task { await searcher.interpret(trimmed, filters: filters, online: online) }
        early = (trimmed, filters, task)
        Task {
            let query = await task.value
            if early?.task == task { understood = (task, query) }
        }
    }

    // MARK: Return

    /// Start a request: everything not yet returned is discarded. Returns this request's ID
    private func begin() -> Int {
        request += 1
        working = true
        return request
    }

    private func cancel() {
        request += 1
        working = false
        if panel?.text == nil { panel = nil }
    }

    /// Do a request in the background; dismiss the waiting look when done (or discarded)
    private func run(_ mine: Int, _ work: @escaping @MainActor () async -> Void) {
        Task {
            await work()
            if request == mine { working = false }
        }
    }

    func submit() {
        guard let searcher else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || filters != Filters() else { dismiss(); return }
        // Literally matching cards stay lit, and gathering takes over when the results fly over
        literalWork?.cancel()
        prefetch()
        let interpretation = early?.task
        let ready = understood?.task == interpretation ? understood?.query : nil
        let (rules, online) = (QueryRules.parse(trimmed, filters: filters), model.online)
        let mine = begin()
        run(mine) { [self] in
            // Understanding not back yet and the rules say it's a card search: search locally first, gather as soon as it's in, don't make people wait for the cloud
            var gathered: [Int64] = []
            if ready == nil, rules.intent == .find {
                let local = await searcher.coarse(rules).shown
                guard request == mine else { return }
                await gather(local, replacing: &gathered, request: mine)
            }
            let q = await interpretation?.value ?? rules
            guard request == mine else { return }
            parsed = q
            switch q.intent {
            case .find:
                for await cards in searcher.finding(q, online: online, over: gathered) {
                    guard request == mine else { return }
                    await gather(cards, replacing: &gathered, request: mine)
                }
                if gathered.isEmpty { notFound(mine) }
            case .inspire:
                panel = Panel(kind: .inspire, text: nil)
                await inspire(scope: q.scope, topic: q.semantic, request: mine)
            case .draw:
                guard let reading = await searcher.draw(q, online: online) else { return notFound(mine) }
                guard request == mine else { return }
                await show(reading.cards, as: .draw, text: reading.text ?? (modelReady ? String(localized: "这次没写出解读，再抽一张试试") : nil))
            case .ask:
                panel = Panel(kind: .ask, text: nil)
                let reading = await searcher.ask(q, online: online)
                guard request == mine else { return }
            let reason = modelReady ? String(localized: "模型没有回应") : String(localized: "要联网、填上密钥才能回答")
            await show(reading.cards, as: .ask, text: reading.text ?? String(localized: "没能写出回答：\(reason)。下面是找到的卡"))
            }
        }
    }

    /// A set of found cards arrived: gather them, or replace the set in view (kept cards slide to new positions). Disperse if the cloud judges none relevant
    private func gather(_ cards: [Int64], replacing gathered: inout [Int64], request mine: Int) async {
        if cards.isEmpty {
            guard !gathered.isEmpty else { return }
            showing = nil
            visitors = 0
            model.canvas?.scatter()
        } else {
            let seen = Set(gathered)
            await show(cards, as: .find, text: nil, fresh: cards.filter { !seen.contains($0) })
            if request == mine { unsettled = mine }
        }
        gathered = cards
    }

    /// The results in view are settled: later cloud results no longer swap the set
    func settle() {
        guard unsettled == request else { return }
        cancel()
    }

    // MARK: Inspiration

    /// Inspiration button: pick from the current board
    func inspireHere() {
        guard inspirationBlocked == nil else { return }
        let scope: Scope = currentBoard.map { .board($0) } ?? .all
        panel = Panel(kind: .inspire, text: nil)
        let mine = begin()
        run(mine) { [self] in await inspire(scope: scope, topic: "", request: mine) }
    }

    /// Shuffle: same scope as last time. Keep the old wording at first, switch to the waiting look only if a new one isn't available right away; a prepared set replaces it directly, without flicker
    @ObservationIgnored private var lastScope: Scope = .all
    @ObservationIgnored private var lastTopic = ""

    func another() {
        guard panel?.kind == .inspire else { return inspireHere() }
        let (mine, previous) = (begin(), panel)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if request == mine, working { panel?.text = nil }
        }
        run(mine) { [self] in await inspire(scope: lastScope, topic: lastTopic, request: mine, keeping: previous) }
    }

    /// keeping: the previous set kept when a shuffle didn't succeed. The cards in view are still gathered, so the panel can't just vanish
    private func inspire(scope: Scope, topic: String, request mine: Int, keeping previous: Panel? = nil) async {
        guard let inspirer = model.inspirer else { return }
        (lastScope, lastTopic) = (scope, topic)
        do {
            let made = try await inspirer.next(scope: scope, topic: topic)
            guard request == mine else { return }
            await show(made.cards, as: .inspire, text: made.text)
        } catch {
            guard request == mine else { return }
            panel = previous
            model.notify(error.localizedDescription)
        }
    }

    /// Prepare several sets of inspiration for this scope in the background, so they appear instantly when the button is pressed
    func prepare() {
        guard inspirationBlocked == nil, let inspirer = model.inspirer else { return }
        let scope: Scope = currentBoard.map { .board($0) } ?? .all
        Task { await inspirer.prepare(scope: scope) }
    }

    // MARK: Gathering

    /// fresh: cards appearing for the first time in this request; revisits are recorded only for them; nil means all
    private func show(_ cards: [Int64], as intent: Intent, text: String?, fresh: [Int64]? = nil) async {
        guard let canvas = model.canvas else { return }
        // The caller just checked the ID: the current ID is this request's
        let mine = request
        guard !cards.isEmpty else { return notFound(mine) }
        let kind: Panel.Kind? = switch intent {
        case .find: nil
        case .inspire: .inspire
        case .draw: text == nil ? nil : .draw
        case .ask: .ask
        }
        await canvas.gather(cards, insets: NSEdgeInsets(top: 0, left: 0, bottom: Chrome.searchReserve, right: kind == nil ? 0 : Chrome.panelReserve))
        // A new request was started during this gathering: discard this one, don't set the text panel or record revisits
        guard request == mine else { return }
        showing = intent
        let revisit: Revisit = switch intent { case .find: .found; case .inspire: .inspired; case .draw: .drawn; case .ask: .asked }
        model.record(revisit, fresh ?? cards)
        panel = kind.map { Panel(kind: $0, text: text, cards: cards, question: parsed.text) }
        visitorsChanged()
    }

    private func notFound(_ mine: Int) {
        guard request == mine else { return }
        panel = nil
        model.canvas?.spotlight(nil)
        model.notify(String(localized: "没找到相关的卡"))
    }

    /// "Continue in Discussion" under a question's answer: the Q&A goes as is into a new discussion, with the supporting cards on the table
    func continueChat() {
        guard let panel, panel.kind == .ask, let text = panel.text else { return }
        model.discussions.continueFromSearch(question: panel.question, answer: text, cards: panel.cards)
    }

    /// Put into the current board: keep result cards from elsewhere (all of them when cards is nil)
    func keepVisitors(_ cards: [Int64]? = nil) {
        guard let canvas = model.canvas else { return }
        let board = canvas.board
        Task {
            do {
                let kept = try await canvas.keepVisitors(cards)
                model.record(.placed, kept, board: board)
                if !kept.isEmpty { model.notify(String(localized: "已放进当前画板 \(kept.count) 张")) }
            } catch {
                model.notify(String(localized: "没放进去：\(error.localizedDescription)"))
            }
            visitorsChanged()
        }
    }

    /// Some were kept (button or context menu): the count on the button updates
    func visitorsChanged() {
        visitors = currentBoard == nil ? 0 : model.canvas?.visitingCards.count ?? 0
    }

    /// Dismiss the text panel and gathered results, keep the text in the search field, literally matching cards light up in place again
    func dismiss() {
        cancel()
        panel = nil
        showing = nil
        visitors = 0
        model.canvas?.scatter()
        typed()
    }

    /// Esc: first dismiss gathered results (inspiration and search each count as a layer), then clear the search field. Returns whether it was handled
    func escape() -> Bool {
        if panel != nil || showing != nil || working { dismiss(); return true }
        if !text.isEmpty || filters != Filters() {
            text = ""
            filters = Filters()
            return true
        }
        return false
    }

    /// Board or view changed: dismiss results, and "This Board" in the scope follows
    func locationChanged() {
        cancel()
        panel = nil
        showing = nil
        visitors = 0
        if case .board = filters.scope { filters.scope = currentBoard.map { .board($0) } ?? .all }
        typed()
    }
}
