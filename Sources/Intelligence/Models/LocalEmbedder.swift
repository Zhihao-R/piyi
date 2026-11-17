import Foundation
import llama

/// Local embeddings: llama.cpp running Qwen3-Embedding-0.6B (8-bit quantized).
/// A llama.cpp context can't be used by several threads at once, so all calls run serially inside a lock; callers put them in utility-priority background tasks so they don't compete with the interface
public final class LocalEmbedder: Embedding, @unchecked Sendable {
    public static let name = String(localized: "本机")
    public var name: String { Self.name }
    public var isReady: Bool { FileManager.default.fileExists(atPath: file.path) }
    public var model: String { LocalModel.name }

    /// Task instruction added before queries, matching how it was written when testing during model selection
    static let task = "Given a search query, retrieve relevant cards from a personal collection of images, notes, web pages and videos"
    /// At most 1024 tokens per piece; longer is truncated
    static let maxTokens: Int32 = 1024

    let file: URL
    /// When true, wait before computing: the model runs on the GPU and competes with drawing, so it yields while you're dragging or zooming the canvas
    let yields: @Sendable () -> Bool
    private let lock = NSLock()
    private var loaded: (model: OpaquePointer, context: OpaquePointer, vocab: OpaquePointer, dims: Int)?
    /// Already released before quitting: computations queued for the lock afterwards won't load the model back
    private var closed = false

    public init(file: URL, yields: @escaping @Sendable () -> Bool = { false }) {
        self.file = file
        self.yields = yields
    }

    /// Load when idle after the app starts: right after install the GPU programs must be compiled on the spot, about 6 seconds, which can't wait until the first search
    public func load() throws {
        _ = try lock.withLock { try ensureLoaded() }
    }

    /// Must be released before quitting, or llama.cpp crashes at process exit because GPU resources weren't reclaimed
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
        // Search queries are what you're waiting on, so they don't yield; only cards being understood in the background do
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
            case .missing: String(localized: "本机向量模型还没下载")
            case .load: String(localized: "本机向量模型加载失败")
            case .compute: String(localized: "本机向量模型计算失败")
            }
        }
    }

    /// The caller already holds the lock
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
        // Take the embedding of the last token (the trailing <|endoftext|>)
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

    /// Tokenize, making sure it ends with <|endoftext|>: the embedding is taken at that position, and without it the embedding is wrong
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
