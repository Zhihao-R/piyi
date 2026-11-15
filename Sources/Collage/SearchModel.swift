import AppKit
import Observation
import Library
import Intelligence
import Canvas
import Tokens

/// 搜索栏和文字面板的状态。一句话先用关键词规则即时给反馈（字面命中的卡原地亮起），
/// 按回车后本机找到的马上聚拢到眼前，云端理解和排序回来、命中的不是同一批卡时才换；灵感、抽一张、提问的文字显示在文字面板
@MainActor @Observable
final class SearchModel {
    var text = "" { didSet { if text != oldValue { typed() } } }
    /// 筛选按钮选的条件；句子里解析出的条件另算，两者合并成同一个查询
    var filters = Filters() { didSet { if filters != oldValue { typed() } } }
    /// 现在生效的条件：打字时是规则解析的，回车后换成模型理解的。筛选按钮上显示它
    private(set) var parsed = Query(text: "")
    /// 正在等模型（理解这句话、精排、写灵感）。本机结果已经聚拢、云端还没回来时也算：结果还没完全定
    private(set) var working = false
    /// 文字面板：灵感的说法、抽一张的解读、提问的回答
    private(set) var panel: Panel?
    /// 聚拢在眼前的是哪种结果；nil 表示没在聚拢
    private(set) var showing: Intent?
    /// 聚拢的结果里有几张来自别的画板、还没留下
    private(set) var visitors = 0

    struct Panel: Equatable {
        enum Kind { case inspire, draw, ask }
        var kind: Kind
        /// nil 表示还在写
        var text: String?
        /// 提问的回答依据的卡：「接着聊」把它们放上桌
        var cards: [Int64] = []
        /// 提问的那句话
        var question = ""
    }

    private unowned let model: AppModel
    private var searcher: Searcher? { model.searcher }
    /// 一次请求的编号：用户又打字、又按了一次时，旧请求回来的结果作废，画面不来回闪
    private var request = 0
    private var literalWork: Task<Void, Never>?
    /// 停手后先把这句话交给模型理解，按回车时多半已经回来了
    private var early: (text: String, filters: Filters, task: Task<Query, Never>)?
    /// 理解已经回来的那一次：回车时直接用它，不必先按规则找一遍
    private var understood: (task: Task<Query, Never>, query: Query)?
    /// 本机结果已经聚拢、还在等云端的那次请求
    private var unsettled: Int?

    init(model: AppModel) { self.model = model }

    /// 当前画板；在几种卡片视图里为 nil
    var currentBoard: Int64? { if case .board(let id) = model.location { id } else { nil } }

    /// 模型能不能用：在线、有能用的密钥
    var modelReady: Bool { model.online && model.keysReady }

    /// 灵感按钮为什么用不了；nil 表示能用
    var inspirationBlocked: String? {
        if !model.online { return String(localized: "离线时用不了灵感：要模型来说出卡片之间的联系") }
        if !model.keysReady { return model.keyRejected ? String(localized: "密钥被拒绝了，换一把才能用灵感") : String(localized: "填上密钥才能用灵感") }
        return nil
    }

    // MARK: 打字

    private func typed() {
        // 还在等模型时又开始打字：正在生成的旧结果作废，回来了也不换画面
        if working { cancel() }
        let rules = QueryRules.parse(text, filters: filters)
        parsed = rules
        literalWork?.cancel()
        literalWork = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let searcher else { return }
            let hits = rules.tokens.isEmpty ? [] : await searcher.literal(rules)
            guard !Task.isCancelled else { return }
            // 命中从有变无时等一会儿再熄：打字途中一两个字对不上，画面不跟着一暗一亮
            if hits.isEmpty, model.canvas?.isSpotlit == true {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            model.canvas?.spotlight(Set(hits))
            // 停手 0.6 秒：提前交给模型理解
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

    // MARK: 回车

    /// 开始一次请求：之前没回来的都作废。返回这次的编号
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

    /// 在后台做一次请求；做完（或作废）时收起等待的样子
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
        // 字面命中的卡继续亮着，等结果飞过来时由聚拢接手
        literalWork?.cancel()
        prefetch()
        let interpretation = early?.task
        let ready = understood?.task == interpretation ? understood?.query : nil
        let (rules, online) = (QueryRules.parse(trimmed, filters: filters), model.online)
        let mine = begin()
        run(mine) { [self] in
            // 理解还没回来、按规则看是找卡片：本机先找，一到就聚拢，不让人等云端
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

    /// 找到的一批卡到了：聚拢，或者换掉眼前那批（留下的卡滑到新位置）。云端判下来一张都不相关时散开
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

    /// 眼前的结果定下来：之后到的云端结果不再换批
    func settle() {
        guard unsettled == request else { return }
        cancel()
    }

    // MARK: 灵感

    /// 灵感按钮：在当前画板里挑
    func inspireHere() {
        guard inspirationBlocked == nil else { return }
        let scope: Scope = currentBoard.map { .board($0) } ?? .all
        panel = Panel(kind: .inspire, text: nil)
        let mine = begin()
        run(mine) { [self] in await inspire(scope: scope, topic: "", request: mine) }
    }

    /// 换一组：和上一次同样的范围。旧的话先留着，一时拿不到新的才换成等待的样子，备好的那组到了直接换，不闪
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

    /// keeping：换一组没换成时留着的上一组。眼前的卡还聚拢着，面板不能凭空消失
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

    /// 后台先为这个范围备好几组灵感，按下按钮时立刻出现
    func prepare() {
        guard inspirationBlocked == nil, let inspirer = model.inspirer else { return }
        let scope: Scope = currentBoard.map { .board($0) } ?? .all
        Task { await inspirer.prepare(scope: scope) }
    }

    // MARK: 聚拢

    /// fresh：这次请求里头一回出现的卡，回看记录只记它们；nil 是全部
    private func show(_ cards: [Int64], as intent: Intent, text: String?, fresh: [Int64]? = nil) async {
        guard let canvas = model.canvas else { return }
        // 调用的地方刚核对过编号：这时的编号就是这次请求的
        let mine = request
        guard !cards.isEmpty else { return notFound(mine) }
        let kind: Panel.Kind? = switch intent {
        case .find: nil
        case .inspire: .inspire
        case .draw: text == nil ? nil : .draw
        case .ask: .ask
        }
        await canvas.gather(cards, insets: NSEdgeInsets(top: 0, left: 0, bottom: Chrome.searchReserve, right: kind == nil ? 0 : Chrome.panelReserve))
        // 聚拢的这会儿又发起了新的请求：这一次作废，不设文字面板、不记回看
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

    /// 提问的回答下面「接着聊」：问答原样带进一段新讨论，依据的卡放上桌
    func continueChat() {
        guard let panel, panel.kind == .ask, let text = panel.text else { return }
        model.discussions.continueFromSearch(question: panel.question, answer: text, cards: panel.cards)
    }

    /// 放进当前画板：结果里来自别处的卡留下来（cards 为 nil 时全部留下）
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

    /// 留下了几张（按钮或右键）：按钮上的张数跟着更新
    func visitorsChanged() {
        visitors = currentBoard == nil ? 0 : model.canvas?.visitingCards.count ?? 0
    }

    /// 收起文字面板和聚拢的结果，搜索框里的字留着，字面命中的卡重新原地亮起
    func dismiss() {
        cancel()
        panel = nil
        showing = nil
        visitors = 0
        model.canvas?.scatter()
        typed()
    }

    /// Esc：先收起聚拢的结果（灵感和搜索各算一层），再清空搜索框。返回有没有处理
    func escape() -> Bool {
        if panel != nil || showing != nil || working { dismiss(); return true }
        if !text.isEmpty || filters != Filters() {
            text = ""
            filters = Filters()
            return true
        }
        return false
    }

    /// 换了画板、换了视图：收起结果，范围里的「当前画板」跟着换
    func locationChanged() {
        cancel()
        panel = nil
        showing = nil
        visitors = 0
        if case .board = filters.scope { filters.scope = currentBoard.map { .board($0) } ?? .all }
        typed()
    }
}
