import Foundation
import Library

/// Understanding queue: turns cards from "only raw content" into "findable by search, understood at a glance".
/// Colors are counted locally, title, description, tags and summary go to generation, and embeddings are computed locally.
/// Whether to do anything depends on the "basis" (Card.contentBasis, a digest of the card's content): if it differs from the last understanding, regenerate;
/// if the text for embeddings or the embedding model changed, recompute embeddings. So whatever was unfinished at quit naturally continues next launch
public actor Understander {
    let store: Store
    let gateway: Gateway
    /// Called after each card finishes; the app refreshes the canvas and status bar from it
    let progress: @Sendable () -> Void

    /// How many to understand at once (cloud generation waits on the network; embeddings are local and one at a time anyway)
    static let parallel = 3

    private var running = false
    /// Something new happened while working: look again after finishing the cards in hand
    private var dirty = false

    public init(store: Store, gateway: Gateway, progress: @escaping @Sendable () -> Void) {
        self.store = store
        self.gateway = gateway
        self.progress = progress
    }

    /// New cards, changed content, a key entered, the model downloaded, or you clicked Retry: look again at which cards need work
    public nonisolated func kick() {
        Task(priority: .utility) { await self.run() }
    }

    /// Work until nothing is left (tests wait on this directly)
    public func run() async {
        dirty = true
        guard !running else { return }
        running = true
        defer { running = false }
        while dirty {
            dirty = false
            await pass()
        }
    }

    private struct Job: Sendable {
        var card: Card
        var generate: Bool
        var waitingKey: Bool
    }

    /// Go over all cards, mark their state, and work newest collected first
    private func pass() async {
        guard let cards = try? await store.extractedCards(), let vectors = try? await store.vectorBases() else { return }
        let model = gateway.embeddingModel
        let canGenerate = gateway.canGenerate
        var jobs: [Job] = [], waiting: [Int64] = [], settled: [Int64] = []
        for card in cards.sorted(by: { $0.collectedAt > $1.collectedAt }) {
            let pending = Self.pending(card, vector: vectors[card.id!], model: model)
            var generate = pending.generate
            var waitingKey = false
            if generate, !canGenerate {
                generate = false
                waitingKey = true
            }
            let colors = card.cover != nil && card.colors == nil && card.understandError == nil
            if generate || colors || pending.vector {
                jobs.append(Job(card: card, generate: generate, waitingKey: waitingKey))
            } else if waitingKey {
                waiting.append(card.id!)
            } else if card.understanding != nil {
                settled.append(card.id!)
            }
        }
        // Cards whose title will change are marked "Reading" on the canvas; ones only getting colors or embeddings are just counted in the status bar
        try? await store.setUnderstanding(.generating, for: jobs.filter(\.generate).map(\.card.id!))
        try? await store.setUnderstanding(.indexing, for: jobs.filter { !$0.generate }.map(\.card.id!))
        try? await store.setUnderstanding(.waitingKey, for: waiting)
        try? await store.setUnderstanding(nil, for: settled)
        progress()

        // Do several at once; when something new happens (a card collected, a key entered) stop queuing more and look again, so new cards don't wait for this whole round
        await withTaskGroup(of: Void.self) { group in
            var pending = jobs.makeIterator()
            func next() -> Bool {
                guard !dirty, let job = pending.next() else { return false }
                group.addTask { await self.understand(job, vectors: vectors) }
                return true
            }
            for _ in 0..<Self.parallel { if !next() { break } }
            for await _ in group { _ = next() }
        }
    }

    private func understand(_ job: Job, vectors: [Int64: (model: String, basis: String)]) async {
        var card = job.card
        let id = card.id!
        var waitingKey = job.waitingKey
        defer { progress() }

        let colors = card.colors == nil ? card.cover.flatMap { ColorAnalysis.json(ofImageAt: store.files.url(of: $0)) } : nil
        var generated: Generated?
        var failure: Error?
        if job.generate {
            do {
                generated = try await write(card)
            } catch is Unavailable {
                waitingKey = true
            } catch {
                // Compute embeddings even if no description was written: the original title and body can still be found by meaning
                failure = error
            }
        }
        // The card was refetched and its content changed meanwhile: discard this result, and redo it with the new content next round
        guard (try? await store.saveUnderstanding(id, basis: card.contentBasis, generated: generated, colors: colors)) == true else { return }
        if let generated { card.apply(generated) }

        let text = Prompt.vectorText(card), basis = Self.basis(text)
        if let model = gateway.embeddingModel, vectors[id].map({ $0.model != model || $0.basis != basis }) ?? true {
            do {
                let values = try await gateway.embed(text, as: .card)
                try await store.saveVector(Vector(cardID: id, model: model, basis: basis, values: values))
            } catch is Unavailable {
                // The local model was deleted: wait until it's downloaded to compute
            } catch {
                return fail(id, error)
            }
        }
        if let failure { return fail(id, failure) }
        try? await store.setUnderstanding(waitingKey ? .waitingKey : nil, for: [id])
    }

    /// Have the model write a card's title, description and tags; key points for long content are asked separately, reading the full text.
    /// If key points don't come out the whole card counts as failed, and a retry redoes both: no separate state for "only key points missing"
    func write(_ card: Card) async throws -> Generated {
        let images = await Prompt.images(for: card, store: store)
        var written = try await gateway.generate(Prompt.understanding(card, images: images.count), images: images, as: Prompt.Reply.self).generated
        if Prompt.needsSummary(card) {
            let passages = Passages.of(card)
            let asking = Prompt.summarizing(card, passages: passages)
            let points = try await gateway.generate(asking.prompt, as: Prompt.Points.self)
            (written.summary, written.anchors) = Prompt.summary(points, passages: passages, whole: asking.whole, for: card)
        }
        return written
    }

    private nonisolated func fail(_ id: Int64, _ error: Error) {
        guard !(error is CancellationError) else { return }
        Task { try? await store.failUnderstanding(id, error.localizedDescription) }
    }

    static func basis(_ text: String) -> String { FileStore.fingerprint(Data(text.utf8)) }

    /// What's left to do: title and description not generated for the current content, embeddings not computed with the current model and text. Failed understanding waits for your retry; cards with no fetched content aren't understood,
    /// nothing is done. Sorting also uses this to judge whether understanding is done; both share one piece of code
    static func pending(_ card: Card, vector: (model: String, basis: String)?, model: String?) -> (generate: Bool, vector: Bool) {
        guard card.understandError == nil, !card.isEmpty else { return (false, false) }
        return (card.understoodBasis != card.contentBasis,
                model != nil && vector.map { $0.model != model || $0.basis != basis(Prompt.vectorText(card)) } ?? true)
    }

    /// Understanding is done: not failed, something to understand, the embedding model present, and nothing left to do
    static func isUnderstood(_ card: Card, vector: (model: String, basis: String)?, model: String?) -> Bool {
        card.understandError == nil && !card.isEmpty && model != nil && pending(card, vector: vector, model: model) == (false, false)
    }
}
