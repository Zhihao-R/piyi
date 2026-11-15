import Foundation
import Library

/// 理解队列：把卡片从「只有原始内容」变成「能被搜到、看一眼就懂」。
/// 颜色在本机统计，标题、描述、标签、总结交给生成，向量在本机算。
/// 要不要做全看「依据」（rebuild-plan 第三节）：卡片内容的依据和上次理解时不同就重新生成，
/// 算向量的那段文字或向量模型变了就重算向量。所以退出时没做完的，下次打开自然接着做
public actor Understander {
    let store: Store
    let gateway: Gateway
    /// 每做完一张卡调一次，App 据此刷新画布和状态栏
    let progress: @Sendable () -> Void

    /// 同时理解几张（云端生成要等网络；向量在本机，本来就一次一条）
    static let parallel = 3

    private var running = false
    /// 正在做的时候又有新情况：做完手上这几张就重新看一遍
    private var dirty = false

    public init(store: Store, gateway: Gateway, progress: @escaping @Sendable () -> Void) {
        self.store = store
        self.gateway = gateway
        self.progress = progress
    }

    /// 有新卡、内容变了、填了密钥、模型下好了、你点了重试：重新看一遍哪些卡要做
    public nonisolated func kick() {
        Task(priority: .utility) { await self.run() }
    }

    /// 做到没有要做的为止（测试里直接等它）
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

    /// 看一遍所有卡，标好状态，按收集时间从新到旧做
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
        // 标题会变的卡画布上标「正在理解」；只补颜色、向量的只在状态栏计数
        try? await store.setUnderstanding(.generating, for: jobs.filter(\.generate).map(\.card.id!))
        try? await store.setUnderstanding(.indexing, for: jobs.filter { !$0.generate }.map(\.card.id!))
        try? await store.setUnderstanding(.waitingKey, for: waiting)
        try? await store.setUnderstanding(nil, for: settled)
        progress()

        // 同时做几张；有新情况（新收了卡、填了密钥）就不再往下排，回头重新看一遍，新卡不用等这一整轮
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
                // 没写出描述也接着算向量：原标题和正文照样能按意思找到
                failure = error
            }
        }
        // 期间卡被重新抓取、内容变了：这次的结果作废，下一轮按新内容重做
        guard (try? await store.saveUnderstanding(id, basis: card.contentBasis, generated: generated, colors: colors)) == true else { return }
        if let generated { card.apply(generated) }

        let text = Prompt.vectorText(card), basis = Self.basis(text)
        if let model = gateway.embeddingModel, vectors[id].map({ $0.model != model || $0.basis != basis }) ?? true {
            do {
                let values = try await gateway.embed(text, as: .card)
                try await store.saveVector(Vector(cardID: id, model: model, basis: basis, values: values))
            } catch is Unavailable {
                // 本机模型被删了：等它下好再算
            } catch {
                return fail(id, error)
            }
        }
        if let failure { return fail(id, failure) }
        try? await store.setUnderstanding(waitingKey ? .waitingKey : nil, for: [id])
    }

    /// 让模型写一张卡的标题、描述、标签；长内容的要点另问一次、读全文。
    /// 要点没写出来就整张算失败、重试时两样一起重做：不为「只差要点」另记一种状态。检查集直接调它
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

    /// 还要做哪些：标题、描述没按当前内容生成过，向量没按当前模型、当前文字算过。理解失败的等你重试，没抓到内容的不理解，
    /// 什么都不做。分拣也按它判断理解做完没有，两边用同一处代码
    static func pending(_ card: Card, vector: (model: String, basis: String)?, model: String?) -> (generate: Bool, vector: Bool) {
        guard card.understandError == nil, !card.isEmpty else { return (false, false) }
        return (card.understoodBasis != card.contentBasis,
                model != nil && vector.map { $0.model != model || $0.basis != basis(Prompt.vectorText(card)) } ?? true)
    }

    /// 理解做完了：没失败，有东西可理解，向量模型在，也没有要做的
    static func isUnderstood(_ card: Card, vector: (model: String, basis: String)?, model: String?) -> Bool {
        card.understandError == nil && !card.isEmpty && model != nil && pending(card, vector: vector, model: model) == (false, false)
    }
}
