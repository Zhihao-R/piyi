import AppKit
import Library
import Canvas
import Wire

extension Inbox {
    /// 本机收件箱：快捷键、服务菜单收的由 App 存进来，浏览器扩展收的由中转程序存进来
    static let local = Inbox(folder: Bridge.inbox(in: Bridge.directory))
}

/// 收集协调者：收件箱里的东西（拖入、粘贴、快捷键、服务菜单、扩展、手机收的都先存在那里）和示例数据，都按同一个顺序调各块
/// 1. 收的是网址，先按网址查重；收过的提到最前，查到的是残缺卡就借这次重新抓取
/// 2. 画布按落点给占位卡找空位，资料块写入占位卡和摆放，卡片马上出现
/// 3. 资料块抽取内容，按内容指纹、最终地址查重，存文件；每张填完就显示
/// 4. 画布按抽到的内容定最终尺寸，一批卡排成整齐的几行，资料块一次写入这批摆放
/// 5. 补全正文（图中文字识别），然后进入理解队列；理解完由分拣决定还放进哪些画板
/// 1～3 步不碰画布，在资料块的 Intake 里
@MainActor
final class Collector {
    private unowned let model: AppModel
    private let extractor: Extractor
    /// 同时抽取几样
    private static let parallel = 4

    init(model: AppModel, extractor: Extractor) {
        self.model = model
        self.extractor = extractor
    }

    /// 收进 board 这个画板，nil 表示只进资料库；point 是落点（世界坐标），nil 表示当前视野中央。
    /// done 报这一批的内容是不是都存进了资料库：收件箱据此决定删不删原件。
    /// heard 在每一样是新的还是收过的都清楚之后调用，入口这时才说「收下了」；给了它，这里就不另外提示「已经收过」
    /// spots：和 sources 一一对应的指定位置（示例画板用），没指定的自动排
    func collect(_ sources: [Source], into board: Int64?, at point: CGPoint? = nil, spots: [Seed.Spot?] = [],
                 then done: @escaping (Bool) -> Void = { _ in }, heard: (@MainActor (Receipt) -> Void)? = nil) {
        guard let canvas = model.canvas, !sources.isEmpty else { return done(sources.isEmpty) }
        let origin = point ?? canvas.visibleCenter
        Task { await run(sources, into: board, at: origin, spots: spots, heard: heard, then: done) }
    }

    private func run(_ sources: [Source], into board: Int64?, at origin: CGPoint, spots: [Seed.Spot?],
                     heard: (@MainActor (Receipt) -> Void)?, then done: (Bool) -> Void) async {
        var saved = false
        defer { done(saved) }
        guard let store = model.store, let canvas = model.canvas else { return }
        do {
            // 1～3
            let occupied = canvas.board == board ? canvas.occupied : []
            let outcomes = try await Intake(store: store, extractor: extractor).collect(sources, on: board) { sources in
                let sizes = sources.map { CardSize.initial(kind: $0.kind, coverAspect: nil, text: nil, hasBody: false) }
                return zip(Layout.arranged(sizes, from: origin, avoiding: occupied), sizes.indices).map { frame, i in
                    Self.frame(of: spots.indices.contains(i) ? spots[i] : nil, size: frame.size, origin: origin) ?? frame
                }
            } report: { @MainActor [weak self] event in
                guard let self else { return }
                switch event {
                case .settled(let source, .existing(let card, let restored, let placed)):
                    await met(card, restored: restored, placed: placed, on: board, quietly: heard != nil)
                    if card.partial != nil { refetch(card, from: source) }
                case .admitted, .settled: model.reload()
                case .judged(let receipt): heard?(receipt)
                }
            }
            saved = Intake.saved(outcomes)

            // 4. 最终尺寸，一批排成整齐的几行，一次写入
            let filled = outcomes.enumerated().compactMap { i, outcome -> (id: Int64, size: CGSize, transcribes: Bool, spot: Seed.Spot?)? in
                guard case .created(let id, let m) = outcome else { return nil }
                let aspect = m.images.first.flatMap(Self.aspect)
                return (id, CardSize.initial(kind: m.kind, coverAspect: aspect, text: m.text, hasBody: !(m.body ?? "").isEmpty),
                        Self.transcribes(m.kind, hasFile: m.original != nil), spots.indices.contains(i) ? spots[i] : nil)
            }
            // 已经收过、这次放进本画板的：有指定位置的也照着摆，比例按它已有的封面算
            let reused = outcomes.enumerated().compactMap { i, outcome -> (id: Int64, size: CGSize, spot: Seed.Spot)? in
                guard case .existing(let card, _, true) = outcome, spots.indices.contains(i), let spot = spots[i] else { return nil }
                let aspect = card.cover.flatMap { CardSize.coverAspect($0, files: store.files) }
                return (card.id!, CardSize.initial(kind: card.kind, coverAspect: aspect, text: card.text, hasBody: !(card.body ?? "").isEmpty), spot)
            }
            if let board, !filled.isEmpty || !reused.isEmpty {
                let mine = Set(filled.map(\.id) + reused.map(\.id))
                let all = try await store.items(on: board)
                let others = all.filter { !mine.contains($0.placement.cardID ?? -1) }.map(\.placement.frame)
                let free = filled.filter { $0.spot == nil }
                var arranged = Layout.arranged(free.map(\.size), from: origin, avoiding: others).makeIterator()
                let placements = Dictionary(all.compactMap { item in item.placement.cardID.map { ($0, item.placement) } }, uniquingKeysWith: { a, _ in a })
                let spotted = filled.compactMap { card in card.spot.map { (card.id, card.size, $0) } } + reused
                try await store.update(spotted.compactMap { id, size, spot in
                    guard var p = placements[id], let frame = Self.frame(of: spot, size: size, origin: origin) else { return nil }
                    p.frame = frame
                    p.rotation = spot.rotation
                    return p
                } + free.compactMap { card in
                    var p = placements[card.id]
                    if let frame = arranged.next() { p?.frame = frame }
                    return p
                })
                model.boardChanged(board)
                model.reload()
            }

            // 5. 补全正文
            completeBodies(filled.map { ($0.id, $0.transcribes) })
        } catch {
            model.notify("收集没完成：\(error.localizedDescription)")
            heard?(Receipt(failed: sources.count))
        }
    }

    /// 指定位置的外框：宽度照指定的，高度没指定就按卡片自己的比例
    nonisolated private static func frame(of spot: Seed.Spot?, size: CGSize, origin: CGPoint) -> CGRect? {
        guard let spot, size.width > 0 else { return nil }
        return CGRect(x: origin.x + spot.origin.x, y: origin.y + spot.origin.y, width: spot.width,
                      height: spot.height ?? (size.height * spot.width / size.width).rounded())
    }

    /// 收到已经收过的（资料块已经把它提到最前、放进了画板、从废纸篓恢复）：记一次回看，告诉你
    private func met(_ existing: Card, restored: Bool, placed: Bool, on board: Int64?, quietly: Bool) async {
        defer { model.reload() }
        if placed, let board { model.record(.placed, [existing.id!], board: board) }
        guard !quietly, let store = model.store else { return }
        let elsewhere = ((try? await store.boards(containing: existing.id!)) ?? []).filter { $0.id != board }.map(\.name)
        var notice = restored ? "已从废纸篓恢复" : "已经收过"
        if placed { notice += "，已放进本画板" }
        if !elsewhere.isEmpty { notice += "，它也在\(elsewhere.map { "「\($0)」" }.joined(separator: "、"))里" }
        model.notify(notice)
    }

    // MARK: 收件箱

    /// 收件箱里还没收的收进来，一次收的一份。从画布收的落回原来的画板和位置（画板已经删了就只进资料库），照旧在窗口里提示；
    /// 别的入口只进资料库（收的那一刻开着哪个画板只是碰巧，等以后自动分拣），查过重后把这一份和回话交给 heard
    func drain(_ inbox: Inbox, heard: @escaping @MainActor (Inbox.Arrival, Receipt) -> Void) {
        Task {
            await inbox.drain { @MainActor [weak self] arrival in
                await withCheckedContinuation { done in
                    guard let self else { return done.resume(returning: false) }
                    if let spot = arrival.spot {
                        let board = spot.board.flatMap { id in self.model.boards.contains { $0.id == id } ? id : nil }
                        self.collect(arrival.sources, into: board, at: CGPoint(x: spot.x, y: spot.y), then: { done.resume(returning: $0) })
                    } else {
                        self.collect(arrival.sources, into: nil, then: { done.resume(returning: $0) }, heard: { heard(arrival, $0) })
                    }
                }
            }
        }
    }

    /// 快捷键、服务菜单存的由它自己回话
    private var quick: QuickCollect?

    /// 本机收件箱：查过重后按各入口存的时候起的编号回话。扩展的回给浏览器；快捷键、服务菜单的由它自己说；
    /// 都不是（上次没收完、这次补收的）且不止一样时在窗口里说一声
    func drainLocal(quick: QuickCollect) {
        self.quick = quick
        drain(.local) { [weak self] arrival, receipt in
            if let id = arrival.id, let source = arrival.sources.first { self?.model.browserExtension.answer(id, receipt, taking: source) }
            if !quick.heard(arrival.id, receipt), arrival.sources.count > 1 { self?.model.notify(receipt.text) }
        }
    }

    /// 拖进、粘贴到画布上的：和别的入口一样先存进收件箱（记着落在哪个画板、哪个位置），卡存好才删；
    /// 抽取到一半退出，下次打开接着收，落回原处
    func receive(_ sources: [Source], into board: Int64?, at point: CGPoint) {
        guard !sources.isEmpty, let quick else { return }
        Task {
            do {
                try await Inbox.local.put(sources, id: UUID().uuidString, spot: Inbox.Spot(board: board, x: point.x, y: point.y))
                drainLocal(quick: quick)
            } catch {
                model.notify("没收下：\(error.localizedDescription)")
            }
        }
    }

    /// 补全正文：在后台、较低的优先级识别图中文字、转录、取平台字幕，每张补完就进入理解队列。
    /// 要在本机转录的排到最后：长视频转录要几分钟，别让同一批的图片、平台视频陪着等
    private func completeBodies(_ cards: [(id: Int64, transcribes: Bool)]) {
        guard let store = model.store else { return }
        let (extractor, understander) = (extractor, model.understander)
        let ordered = cards.filter { !$0.transcribes } + cards.filter(\.transcribes)
        Task.detached(priority: .utility) {
            for card in ordered {
                try? await extractor.completeBody(of: card.id, in: store)
                understander?.kick()
            }
        }
    }

    /// 上次退出时没做完的补全正文，这次接着做：分拣要等它
    func completeUnfinishedBodies() {
        Task {
            let cards = (try? await model.store?.bodiesToComplete()) ?? []
            completeBodies(cards.map { ($0.id!, Self.transcribes($0.kind, hasFile: $0.original != nil)) })
        }
    }

    /// 要在本机转录：有文件的视频、音频
    private static func transcribes(_ kind: Kind, hasFile: Bool) -> Bool { (kind == .video || kind == .audio) && hasFile }

    // MARK: 重新抓取

    /// 正在重新抓的卡：同一张同时只抓一份
    private var refetching: Set<Int64> = []
    /// 这次运行里扩展连上时已经自动补抓过的卡：没登录的网站浏览器每次重连都会再失败，只自动试一次，之后靠右键「重新抓取」
    private var triedWithBrowser: Set<Int64> = []

    /// 残缺卡重新抓一次（这次收来的就是它时，用这次收来的内容）；还是没抓全就留着，原因更新
    func refetch(_ card: Card, from source: Source? = nil) {
        guard let store = model.store, let id = card.id, let url = card.url.flatMap(URL.init(string:)),
              refetching.insert(id).inserted else { return }
        let extractor = extractor
        Task {
            defer { refetching.remove(id) }
            try? await store.markExtracting(id)
            model.reload()
            let m = await extractor.material(for: source ?? .url(url))
            _ = try? await store.fill(id, with: m)
            model.reload()
            completeBodies([(id, Self.transcribes(m.kind, hasFile: m.original != nil))])
        }
    }

    /// 打开时、联网后：断网时收的、上次没抓完的残缺卡自动补抓
    func refetchOffline() {
        Task {
            for card in (try? await model.store?.partialCards()) ?? [] where card.partial?.waitsForNetwork == true { refetch(card) }
        }
    }

    /// 扩展连上后：等浏览器打开的、要登录的残缺卡自动补抓（浏览器里可能已经登录过）
    func refetchForBrowser() {
        Task {
            for card in (try? await model.store?.partialCards()) ?? [] where card.partial?.waitsForBrowser == true {
                guard let id = card.id, triedWithBrowser.insert(id).inserted else { continue }
                refetch(card)
            }
        }
    }

    // MARK: 读剪贴板、拖放

    /// 剪贴板或拖放里的东西：文件、图片（带所在页面的网址）、网址、文字。一串网址拆成一个个网址
    static func sources(in pasteboard: NSPasteboard) -> [Source] {
        var out: [Source] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL {
                out += FileExtractor.files(in: url).map(Source.file)
            } else if let data = imageData(item) {
                let page = [NSPasteboard.PasteboardType("org.chromium.source-url"), .URL].lazy.compactMap { item.string(forType: $0) }.first
                out.append(.image(data, page: page.flatMap(URL.init(string:))))
            } else if let string = item.string(forType: .URL), let url = URL(string: string), ["http", "https"].contains(url.scheme) {
                out.append(.url(url))
            } else if let text = item.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out += FileExtractor.sources(inText: text)
            }
        }
        return out
    }

    private static func imageData(_ item: NSPasteboardItem) -> Data? {
        for type in [NSPasteboard.PasteboardType("com.compuserve.gif"), .png, NSPasteboard.PasteboardType("public.jpeg"), .tiff] {
            if let data = item.data(forType: type) { return data }
        }
        return nil
    }

    /// 封面的高宽比，从文件头读
    nonisolated private static func aspect(_ data: Data) -> CGFloat? {
        FileExtractor.pixelSize(data).map { $0.height / $0.width }
    }
}
