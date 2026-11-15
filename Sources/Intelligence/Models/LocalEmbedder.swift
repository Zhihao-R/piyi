import Foundation
import llama

/// 本机向量：llama.cpp 跑 Qwen3-Embedding-0.6B（8 位量化）。
/// llama.cpp 的上下文不能多线程同时用，所有调用在锁里串行做；调用方放在 utility 优先级的后台任务里，不和界面抢
public final class LocalEmbedder: Embedding, @unchecked Sendable {
    public static let name = "本机"
    public var name: String { Self.name }
    public var isReady: Bool { FileManager.default.fileExists(atPath: file.path) }
    public var model: String { LocalModel.name }

    /// 查询前面加的任务说明，和选模型时测试的写法一致
    static let task = "Given a search query, retrieve relevant cards from a personal collection of images, notes, web pages and videos"
    /// 一段最多 1024 个词元，超出截断
    static let maxTokens: Int32 = 1024

    let file: URL
    /// 为 true 时先等着再算：模型在显卡上算，和画面绘制抢显卡，你正在拖动、缩放画布时让一让
    let yields: @Sendable () -> Bool
    private let lock = NSLock()
    private var loaded: (model: OpaquePointer, context: OpaquePointer, vocab: OpaquePointer, dims: Int)?
    /// 退出前释放过了：之后排队等锁的计算不再把模型加载回来
    private var closed = false

    public init(file: URL, yields: @escaping @Sendable () -> Bool = { false }) {
        self.file = file
        self.yields = yields
    }

    /// App 启动后空闲时先加载：新装后第一次要现场编译显卡程序，约 6 秒，不能等到第一次搜索
    public func load() throws {
        _ = try lock.withLock { try ensureLoaded() }
    }

    /// 退出前必须释放，否则 llama.cpp 在进程退出时因为显卡资源没收回而崩溃
    public func unload() {
        lock.withLock {
            closed = true
            guard let l = loaded else { return }
            llama_free(l.context)
            llama_model_free(l.model)
            loaded = nil
        }
    }

    public func embed(_ text: String, as role: EmbeddingRole) async throws -> [Float] {
        let input = role == .query ? "Instruct: \(Self.task)\nQuery:\(text)" : text
        // 搜索的查询是你在等的，不让；后台理解的卡片才让
        while role == .card, yields() { try await Task.sleep(for: .milliseconds(200)) }
        return try lock.withLock { try compute(input) }
    }

    private func compute(_ input: String) throws -> [Float] {
        let l = try ensureLoaded()
        let tokens = tokenize(input, vocab: l.vocab)
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for (pos, token) in tokens.enumerated() {
            batch.token[pos] = token
            batch.pos[pos] = Int32(pos)
            batch.n_seq_id[pos] = 1
            batch.seq_id[pos]![0] = 0
            batch.logits[pos] = pos == tokens.count - 1 ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        llama_memory_clear(llama_get_memory(l.context), true)
        guard llama_decode(l.context, batch) == 0, let out = llama_get_embeddings_seq(l.context, 0) else { throw Failure.compute }
        let v = Array(UnsafeBufferPointer(start: out, count: l.dims))
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / norm }
    }

    enum Failure: LocalizedError {
        case missing, load, compute
        var errorDescription: String? {
            switch self {
            case .missing: "本机向量模型还没下载"
            case .load: "本机向量模型加载失败"
            case .compute: "本机向量模型计算失败"
            }
        }
    }

    /// 调用方已经拿着锁
    private func ensureLoaded() throws -> (model: OpaquePointer, context: OpaquePointer, vocab: OpaquePointer, dims: Int) {
        if let loaded { return loaded }
        guard isReady, !closed else { throw Failure.missing }
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(file.path, modelParams) else { throw Failure.load }
        var params = llama_context_default_params()
        params.embeddings = true
        // 取最后一个词元（结尾的 <|endoftext|>）的向量
        params.pooling_type = LLAMA_POOLING_TYPE_LAST
        params.n_ctx = UInt32(Self.maxTokens)
        params.n_batch = params.n_ctx
        params.n_ubatch = params.n_ctx
        params.n_seq_max = 1
        guard let context = llama_init_from_model(model, params) else { llama_model_free(model); throw Failure.load }
        let l = (model, context, llama_model_get_vocab(model)!, Int(llama_model_n_embd(model)))
        loaded = l
        return l
    }

    /// 分词，并保证以 <|endoftext|> 结尾：向量取的就是这个位置，少了它向量就不对
    private func tokenize(_ text: String, vocab: OpaquePointer) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: Int(Self.maxTokens))
        let n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Self.maxTokens, true, true)
        var result = Array(tokens.prefix(Int(max(n, 0))).prefix(Int(Self.maxTokens) - 1))
        let eos = llama_vocab_eos(vocab)
        if result.last != eos { result.append(eos) }
        return result
    }
}
