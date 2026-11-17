import Foundation
import Synchronization
import Library

/// Cloud: calls large models through a provider (Vendor), for both generation and chat. Most use the same request format (Claude's is in Claude.swift), sent directly with the system's built-in networking.
/// With OpenRouter, judging goes separately to Jev routed through it (see Jev.swift), sharing this key
public final class Cloud: Generation, Keyed {
    /// Which provider, which model, whether to think: changeable in Settings
    private let chosen: Mutex<CloudSetup>
    public var setup: CloudSetup { chosen.withLock { $0 } }
    public var name: String { setup.vendor.name }

    let session: URLSession
    /// Manually run real cloud tests and self-checks read the key from an environment variable; normally nil, reading this provider's key from the key file
    private let keyOverride: (@Sendable (Vendor) -> String?)?
    /// Why the provider last rejected a request (wrong model name, wrong address, not enabled); cleared after a later success or settings change. The settings page uses it for hints
    private let failure = Mutex<String?>(nil)
    public var lastFailure: String? { failure.withLock { $0 } }
    /// The key that was rejected: no more requests are sent with it
    private let rejected = Mutex<String?>(nil)
    /// Total USD spent by requests from this instance, summed from usage.cost in answers (only OpenRouter reports it). Manually run real cloud tests use it to check spending
    private let cost = Mutex(0.0)
    var spent: Double { cost.withLock { $0 } }
    /// The model's context length: remembered once asked
    private let context = Mutex<Int?>(nil)

    public init(_ setup: CloudSetup = CloudSetup(), session: URLSession = .shared, key: (@Sendable (Vendor) -> String?)? = nil) {
        self.session = session
        chosen = Mutex(setup)
        keyOverride = key
    }

    /// This provider's key: one per provider, stored separately
    private func key(for vendor: Vendor) -> String? { keyOverride.map { $0(vendor) } ?? KeyFile.key(for: vendor.rawValue) }

    public var keyState: KeyState { keyState(for: setup.vendor) }

    private func keyState(for vendor: Vendor) -> KeyState {
        guard let key = key(for: vendor) else { return .missing }
        return key == rejected.withLock({ $0 }) ? .rejected : .ready
    }

    /// The key works, and we know where to send and which model to use
    public var isReady: Bool {
        let setup = setup
        return keyState(for: setup.vendor) == .ready && setup.base != nil && setup.chosenModel != nil
    }

    public func setKey(_ key: String) throws { try KeyFile.setKey(key, for: setup.vendor.rawValue) }

    /// Switch provider or model: later requests all follow the new one; context length goes with the model and must be asked again.
    /// After a change of place, "this key was rejected" no longer holds: maybe the previous address was just mistyped
    public func configure(_ setup: CloudSetup) {
        let moved = chosen.withLock { old in
            defer { old = setup }
            return old.vendor != setup.vendor || old.base != setup.base
        }
        context.withLock { $0 = nil }
        failure.withLock { $0 = nil }
        if moved { rejected.withLock { $0 = nil } }
    }

    public struct Failure: LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    public func generate(_ prompt: String, images: [Data], careful: Bool) async throws -> String {
        try await generate(prompt, images: images, careful: careful, judging: false)
    }

    /// judging: use the judge model (the same one if none was entered separately and the provider recommends no other)
    func generate(_ prompt: String, images: [Data], careful: Bool, judging: Bool) async throws -> String {
        let setup = setup
        guard let model = judging ? setup.chosenJudgeModel : setup.chosenModel else { throw Unavailable.notReady }
        if setup.vendor.wire == .messages { return try await claudeGenerate(prompt, images: images, careful: careful, model: model) }
        let content: [[String: Any]] = [["type": "text", "text": prompt]] + images.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
        }
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": content]]]
        if setup.vendor.jsonMode { body["response_format"] = ["type": "json_object"] }
        // Thinking is normally off to save time; only let it think when the judgment isn't confident enough
        body.merge(setup.vendor.thinkingFields(on: careful)) { $1 }
        body.merge(setup.vendor.extras) { $1 }
        let response = try await post("chat/completions", body)
        guard let choices = response["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { throw Failure(message: String(localized: "\(displayed(name)) 没有返回内容")) }
        return text
    }

    /// Generate with the judge model: handed to the gateway to stand in for the judging capability
    public var judging: any Generation { Judging(cloud: self) }

    private struct Judging: Generation {
        let cloud: Cloud
        var name: String { cloud.name }
        var isReady: Bool { cloud.isReady }
        func generate(_ prompt: String, images: [Data], careful: Bool) async throws -> String {
            try await cloud.generate(prompt, images: images, careful: careful, judging: true)
        }
    }

    func post(_ path: String, _ body: [String: Any], headers: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await send(path, body, headers: headers, fetch: { try await self.session.data(for: $0) }, errorData: { $0 })
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = json["error"] as? [String: Any] { throw Failure(message: String(localized: "\(displayed(name))：\(error["message"] as? String ?? String(localized: "未知错误"))")) }
        charge(json["usage"])
        return json
    }

    /// Send the request and get back a response with a normal status. Shared by streaming and non-streaming: remembers a rejected key; on rate limits and server errors waits and retries, up to three times.
    /// errorData reads the error response into complete data, so the error message can be extracted
    func send<Response>(_ path: String, _ body: [String: Any], headers: [String: String] = [:],
                        fetch: (URLRequest) async throws -> (Response, URLResponse),
                        errorData: (Response) async throws -> Data) async throws -> Response {
        // Provider, address and key are taken from settings at the same moment: if the provider changes right then, this provider's key won't be sent to the other
        let setup = setup
        let name = setup.vendor.name
        guard let key = key(for: setup.vendor), key != rejected.withLock({ $0 }), let base = setup.base else { throw Unavailable.notReady }
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if setup.vendor.wire == .messages {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if setup.vendor == .openRouter { request.setValue("Piyi", forHTTPHeaderField: "X-Title") }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var lastError: Error = Failure(message: String(localized: "\(displayed(name)) 请求失败"))
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt))) }
            let (response, http): (Response, URLResponse)
            do { (response, http) = try await fetch(request) } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                lastError = error
                continue
            }
            let status = (http as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                failure.withLock { $0 = nil }
                return response
            }
            // Wrong key: remember this one; cards stay at "Waiting for a key" instead of each recording a failure
            if status == 401 {
                rejected.withLock { $0 = key }
                throw Unavailable.notReady
            }
            let json = (try? JSONSerialization.jsonObject(with: try await errorData(response))) as? [String: Any] ?? [:]
            lastError = Failure(message: String(localized: "\(displayed(name))：\((json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)")"))
            guard status == 429 || status >= 500 else {
                failure.withLock { $0 = lastError.localizedDescription }
                throw lastError
            }
        }
        throw lastError
    }

    /// Add up spending from usage.cost in the answer
    @discardableResult
    private func charge(_ usage: Any?) -> Double {
        guard let charge = ((usage as? [String: Any])?["cost"] as? NSNumber)?.doubleValue else { return 0 }
        cost.withLock { $0 += charge }
        return charge
    }
}

// MARK: Chat

extension Cloud: Conversation {
    /// Send a streaming request and get back the answer line by line as it arrives
    func stream(_ path: String, _ body: [String: Any], headers: [String: String] = [:]) async throws -> URLSession.AsyncBytes {
        try await send(path, body, headers: headers, fetch: { try await self.session.bytes(for: $0) }) { bytes in
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return data
        }
    }

    /// Read context length from OpenRouter's model list, remembered once read; other providers have no such list, so it can't be asked
    public func contextLength() async -> Int? {
        if let known = context.withLock({ $0 }) { return known }
        let setup = setup
        guard setup.vendor == .openRouter, let model = setup.chosenModel, let (data, _) = try? await session.data(from: URL(string: "https://openrouter.ai/api/v1/models")!),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = json["data"] as? [[String: Any]],
              let length = (models.first { $0["id"] as? String == model }?["context_length"] as? NSNumber)?.intValue else { return nil }
        // The model was switched while asking: don't remember it
        if setup == self.setup { context.withLock { $0 = length } }
        return length
    }

    /// chat/completions with stream on: the server pushes back SSE piece by piece (each line "data: {…}"), and text is passed on as it arrives;
    /// tool call names and arguments arrive in several pieces and are passed on together once complete, before the end; the last piece carries usage and cost
    public func converse(_ chat: Chat) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if setup.vendor.wire == .messages {
                        try await claudeConverse(chat) { continuation.yield($0) }
                        continuation.finish()
                        return
                    }
                    let bytes = try await stream("chat/completions", body(chat))
                    var calls: [Int: ToolCall] = [:]
                    var usage = ChatUsage()
                    for try await line in bytes.lines {
                        // Comment lines like ": OPENROUTER PROCESSING" are keep-alives
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        if payload == "[DONE]" { break }
                        guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                        if let error = json["error"] as? [String: Any] { throw Failure(message: String(localized: "\(displayed(name))：\(error["message"] as? String ?? String(localized: "未知错误"))")) }
                        if let used = json["usage"] as? [String: Any] { usage = Self.usage(used, cost: charge(used)) }
                        guard let delta = ((json["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] else { continue }
                        // Thinking: OpenRouter puts it in reasoning, others in reasoning_content
                        if let thought = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String, !thought.isEmpty {
                            continuation.yield(.thought(thought))
                        }
                        if let text = delta["content"] as? String, !text.isEmpty { continuation.yield(.text(text)) }
                        for piece in delta["tool_calls"] as? [[String: Any]] ?? [] {
                            let i = (piece["index"] as? NSNumber)?.intValue ?? 0
                            var call = calls[i] ?? ToolCall(id: "", name: "", arguments: "")
                            if let id = piece["id"] as? String, !id.isEmpty { call.id = id }
                            // Some providers (Gemini) attach a credential to the call that must be sent back unchanged next round
                            if let extra = piece["extra_content"], let data = try? JSONSerialization.data(withJSONObject: extra) {
                                call.extra = String(decoding: data, as: UTF8.self)
                            }
                            let function = piece["function"] as? [String: Any]
                            if let name = function?["name"] as? String { call.name += name }
                            if let arguments = function?["arguments"] as? String { call.arguments += arguments }
                            calls[i] = call
                        }
                    }
                    for (i, call) in calls.sorted(by: { $0.key < $1.key }) {
                        var call = call
                        if call.id.isEmpty { call.id = "call_\(i)" }
                        continuation.yield(.call(call))
                    }
                    continuation.yield(.done(usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func body(_ chat: Chat) -> [String: Any] {
        let setup = setup
        let model = setup.chosenModel ?? ""
        // Anthropic and Google models via OpenRouter need explicit cache marks; others (DeepSeek) cache the start automatically
        let marks = setup.vendor == .openRouter && (model.hasPrefix("anthropic/") || model.hasPrefix("google/"))
        let messages: [[String: Any]] = chat.messages.enumerated().map { m, message in
            var out: [String: Any] = ["role": message.role.rawValue]
            switch message.role {
            case .system, .tool:
                out["content"] = message.text
            case .assistant:
                // Only calling tools, not speaking: content left empty
                out["content"] = message.text.isEmpty && !message.calls.isEmpty ? NSNull() : message.text
            case .user:
                out["content"] = message.parts.enumerated().map { p, part -> [String: Any] in
                    var json: [String: Any] = switch part {
                    case .text(let text): ["type": "text", "text": text]
                    case .image(let data): ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]]
                    }
                    if marks, chat.stableThrough == Chat.Position(message: m, part: p) { json["cache_control"] = ["type": "ephemeral"] }
                    return json
                }
            }
            if !message.calls.isEmpty {
                out["tool_calls"] = message.calls.map { call -> [String: Any] in
                    var json: [String: Any] = ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
                    if setup.vendor.sendsCallExtrasBack, let extra = call.extra, let value = try? JSONSerialization.jsonObject(with: Data(extra.utf8)) { json["extra_content"] = value }
                    return json
                }
            }
            if let id = message.callID { out["tool_call_id"] = id }
            // What Claude stored is its own whole round of content, not text other providers can read
            if let thought = message.thought, setup.vendor.sendsThoughtsBack, Self.claudeTurn(thought) == nil { out["reasoning_content"] = thought }
            return out
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
        ]
        body.merge(setup.vendor.thinkingFields(on: setup.thinking)) { $1 }
        // Same as generate: OpenRouter picks the provider by recent response speed. Each round may land on a different provider; cache hit rate is measured by the test set (discussion-plan.md section 5)
        body.merge(setup.vendor.extras) { $1 }
        body.merge(setup.vendor.streamExtras) { $1 }
        if !chat.tools.isEmpty {
            body["tools"] = chat.tools.map { tool in
                ["type": "function", "function": ["name": tool.name, "description": tool.description,
                                                  "parameters": (try? JSONSerialization.jsonObject(with: Data(tool.parameters.utf8))) ?? [:]]]
            }
            if !chat.toolsAllowed { body["tool_choice"] = "none" }
        }
        return body
    }

    static func usage(_ json: [String: Any], cost: Double) -> ChatUsage {
        let int = { (value: Any?) in (value as? NSNumber)?.intValue ?? 0 }
        return ChatUsage(input: int(json["prompt_tokens"]), cached: int((json["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]),
                         output: int(json["completion_tokens"]), cost: cost)
    }
}
