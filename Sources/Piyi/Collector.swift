import AppKit
import Library
import Canvas
import Wire

extension Inbox {
    /// Local inbox: shortcut and Services menu collections are stored by the App, browser extension collections by the relay
    static let local = Inbox(folder: Bridge.inbox(in: Bridge.directory))
}

/// Collection coordinator: inbox items (drag-in, paste, shortcut, Services menu, extension, phone all land there first) and sample data call each part in the same order
/// 1. If it's a URL, deduplicate by URL first; already-collected ones move to the front, and if it's an incomplete card this collection is used to refetch it
/// 2. The canvas finds free spots for placeholder cards by drop point, the data layer writes the placeholder cards and placements, cards appear at once
/// 3. The data layer extracts content, deduplicates by content fingerprint and final URL, stores files; each card shows as soon as it's filled
/// 4. The canvas sets final sizes from the extracted content, a batch is arranged in neat rows, the data layer writes the batch's placements at once
/// 5. Complete the body text (text recognition in images), then enter the understanding queue; after understanding, sorting decides which other boards it goes into
/// Steps 1–3 don't touch the canvas; they're in the data layer's Intake
@MainActor
final class Collector {
    private unowned let model: AppModel
    private let extractor: Extractor
    /// How many to extract at once
    private static let parallel = 4

    init(model: AppModel, extractor: Extractor) {
        self.model = model
        self.extractor = extractor
    }

    /// Collect into the board `board`, nil means library only; point is the drop point (world coordinates), nil means the center of the current view.
    /// done reports whether all of this batch's content was saved to the library: the inbox uses it to decide whether to delete the originals.
    /// heard is called once it's clear whether each item is new or already collected; only then does the entry point say "collected". If given, this doesn't separately hint "Already collected"
    /// presets: positions and understanding results fixed in advance, one-to-one with sources (for the sample board); ones without a position are arranged automatically
    func collect(_ sources: [Source], into board: Int64?, at point: CGPoint? = nil, presets: [Seed.Preset] = [],
                 then done: @escaping (Bool) -> Void = { _ in }, heard: (@MainActor (Receipt) -> Void)? = nil) {
        guard let canvas = model.canvas, !sources.isEmpty else { return done(sources.isEmpty) }
        let origin = point ?? canvas.visibleCenter
        Task { await run(sources, into: board, at: origin, presets: presets, heard: heard, then: done) }
    }

    private func run(_ sources: [Source], into board: Int64?, at origin: CGPoint, presets: [Seed.Preset],
                     heard: (@MainActor (Receipt) -> Void)?, then done: (Bool) -> Void) async {
        var saved = false
        defer { done(saved) }
        guard let store = model.store, let canvas = model.canvas else { return }
        let preset: @Sendable (Int) -> Seed.Preset = { presets.indices.contains($0) ? presets[$0] : Seed.Preset() }
        do {
            // 1～3
            let occupied = canvas.board == board ? canvas.occupied : []
            let outcomes = try await Intake(store: store, extractor: extractor).collect(sources, on: board) { sources in
                let sizes = sources.map { CardSize.initial(kind: $0.kind, coverAspect: nil, text: nil, hasBody: false) }
                return zip(Layout.arranged(sizes, from: origin, avoiding: occupied), sizes.indices).map { frame, i in
                    Self.frame(of: preset(i).spot, size: frame.size, origin: origin) ?? frame
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

            // Write pre-generated understanding results directly, with the basis recorded against the card's current content: understanding then won't call the model
            for (i, outcome) in outcomes.enumerated() {
                guard case .created(let id, _) = outcome, let understood = preset(i).understood, let card = try await store.card(id) else { continue }
                try await store.saveUnderstanding(id, basis: card.contentBasis, generated: understood, colors: nil)
            }

            // 4. Final sizes; a batch arranged in neat rows, written at once
            let filled = outcomes.enumerated().compactMap { i, outcome -> (id: Int64, size: CGSize, transcribes: Bool, spot: Seed.Spot?, understood: Generated?)? in
                guard case .created(let id, let m) = outcome else { return nil }
                let aspect = m.images.first.flatMap(Self.aspect)
                return (id, CardSize.initial(kind: m.kind, coverAspect: aspect, text: m.text, hasBody: !(m.body ?? "").isEmpty),
                        Self.transcribes(m.kind, hasFile: m.original != nil), preset(i).spot, preset(i).understood)
            }
            // Already collected and added to this board this time: lay out ones with a given position as given, aspect ratio from its existing cover
            let reused = outcomes.enumerated().compactMap { i, outcome -> (id: Int64, size: CGSize, spot: Seed.Spot)? in
                guard case .existing(let card, _, true) = outcome, let spot = preset(i).spot else { return nil }
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

            // 5. Complete the body text
            completeBodies(filled.map { ($0.id, $0.transcribes, $0.understood) })
        } catch {
            model.notify(String(localized: "收集没完成：\(error.localizedDescription)"))
            heard?(Receipt(failed: sources.count))
        }
    }

    /// Frame for a given position: width as given; height, if not given, from the card's own aspect ratio
    nonisolated private static func frame(of spot: Seed.Spot?, size: CGSize, origin: CGPoint) -> CGRect? {
        guard let spot, size.width > 0 else { return nil }
        return CGRect(x: origin.x + spot.origin.x, y: origin.y + spot.origin.y, width: spot.width,
                      height: spot.height ?? (size.height * spot.width / size.width).rounded())
    }

    /// Received something already collected (the data layer already moved it to the front, put it in the board, restored it from Trash): record a revisit and tell you
    private func met(_ existing: Card, restored: Bool, placed: Bool, on board: Int64?, quietly: Bool) async {
        defer { model.reload() }
        if placed, let board { model.record(.placed, [existing.id!], board: board) }
        guard !quietly, let store = model.store else { return }
        let elsewhere = ((try? await store.boards(containing: existing.id!)) ?? []).filter { $0.id != board }.map(\.name)
        var notice = restored ? String(localized: "已从废纸篓恢复") : String(localized: "已经收过")
        if placed { notice += String(localized: "，已放进本画板") }
        if !elsewhere.isEmpty { notice += String(localized: "，它也在\(elsewhere.map(quoted).formatted(.list(type: .and)))里") }
        model.notify(notice)
    }

    // MARK: Inbox

    /// Collect what's not yet collected in the inbox, one item per collect. Those collected from the canvas land back on their original board and position (library only if the board was deleted), with hints in the window as before;
    /// other entry points go into the library only (which board was open at the moment of collection is just chance; sort automatically later), and after deduplication hand this item and the reply to heard
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

    /// Shortcut and Services menu items reply on their own
    private var quick: QuickCollect?

    /// Local inbox: after deduplication, reply using the ID each entry point assigned when storing. Extension items reply to the browser; shortcut and Services menu items speak for themselves;
    /// if none of these (left uncollected last time, collected now) and more than one, mention it in the window
    func drainLocal(quick: QuickCollect) {
        self.quick = quick
        drain(.local) { [weak self] arrival, receipt in
            if let id = arrival.id, let source = arrival.sources.first { self?.model.browserExtension.answer(id, receipt, taking: source) }
            if !quick.heard(arrival.id, receipt), arrival.sources.count > 1 { self?.model.notify(receipt.text) }
        }
    }

    /// Dragged or pasted onto the canvas: stored in the inbox first like other entry points (noting which board and position), deleted only once the card is saved;
    /// if the app quits mid-extraction, collection continues on next launch and lands back in place
    func receive(_ sources: [Source], into board: Int64?, at point: CGPoint) {
        guard !sources.isEmpty, let quick else { return }
        Task {
            do {
                try await Inbox.local.put(sources, id: UUID().uuidString, spot: Inbox.Spot(board: board, x: point.x, y: point.y))
                drainLocal(quick: quick)
            } catch {
                model.notify(String(localized: "没收下：\(error.localizedDescription)"))
            }
        }
    }

    /// Complete the body text: in the background at lower priority, recognize text in images, transcribe, fetch platform subtitles; each card enters the understanding queue once done.
    /// Local transcription goes last: long videos take minutes to transcribe, so images and platform videos in the same batch shouldn't wait on it
    /// understood: pre-generated understanding results. Completing the body text (image text, transcripts) changes the card content, so re-record the basis against the new content to avoid calling the model again
    private func completeBodies(_ cards: [(id: Int64, transcribes: Bool, understood: Generated?)]) {
        guard let store = model.store else { return }
        let (extractor, understander) = (extractor, model.understander)
        let ordered = cards.filter { !$0.transcribes } + cards.filter(\.transcribes)
        Task.detached(priority: .utility) {
            for card in ordered {
                try? await extractor.completeBody(of: card.id, in: store)
                if let understood = card.understood, let now = try? await store.card(card.id) {
                    try? await store.saveUnderstanding(card.id, basis: now.contentBasis, generated: understood, colors: nil)
                }
                understander?.kick()
            }
        }
    }

    /// Body-text completion unfinished at last quit continues this time: sorting waits for it
    func completeUnfinishedBodies() {
        Task {
            let cards = (try? await model.store?.bodiesToComplete()) ?? []
            completeBodies(cards.map { ($0.id!, Self.transcribes($0.kind, hasFile: $0.original != nil), nil) })
        }
    }

    /// Needs local transcription: videos and audio with a file
    private static func transcribes(_ kind: Kind, hasFile: Bool) -> Bool { (kind == .video || kind == .audio) && hasFile }

    // MARK: Fetch again

    /// Cards being refetched: only one fetch per card at a time
    private var refetching: Set<Int64> = []
    /// Cards auto-refetched in this run when the extension connected: sites you're not logged into fail on every reconnect, so auto-try only once, after that rely on the context menu "Fetch Again"
    private var triedWithBrowser: Set<Int64> = []

    /// Refetch an incomplete card once (if this collection is that card, use the content just collected); if still incomplete, keep it and update the reason
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
            completeBodies([(id, Self.transcribes(m.kind, hasFile: m.original != nil), nil)])
        }
    }

    /// On launch and once online: auto-refetch incomplete cards collected offline or left unfinished last time
    func refetchOffline() {
        Task {
            for card in (try? await model.store?.partialCards()) ?? [] where card.partial?.waitsForNetwork == true { refetch(card) }
        }
    }

    /// After the extension connects: auto-refetch incomplete cards waiting for the browser or needing login (you may have logged in in the browser already)
    func refetchForBrowser() {
        Task {
            for card in (try? await model.store?.partialCards()) ?? [] where card.partial?.waitsForBrowser == true {
                guard let id = card.id, triedWithBrowser.insert(id).inserted else { continue }
                refetch(card)
            }
        }
    }

    // MARK: Reading the clipboard, drag and drop

    /// Things on the clipboard or in a drop: files, images (with the URL of their page), URLs, text. A string of URLs is split into individual URLs
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

    /// Cover aspect ratio (height/width), read from the file header
    nonisolated private static func aspect(_ data: Data) -> CGFloat? {
        FileExtractor.pixelSize(data).map { $0.height / $0.width }
    }
}
