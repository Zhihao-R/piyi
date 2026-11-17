import Foundation
import Synchronization
import Library

/// 云端：经一家服务商（Vendor）调用大模型，生成和对话都走它。多数是同一种请求格式（Claude 的见 Claude.swift），用系统自带的网络接口直接发。
/// 用 OpenRouter 时，判断另走它转接的 Jev（见 Jev.swift），共用这把密钥
public final class Cloud: Generation, Keyed {
    /// 哪家、哪个模型、要不要思考：设置里可以换
    private let chosen: Mutex<CloudSetup>
    public var setup: CloudSetup { chosen.withLock { $0 } }
    public var name: String { setup.vendor.name }

    let session: URLSession
    /// 手动跑的真实云端测试、自查从环境变量读密钥；平时为 nil，读密钥文件里这家的那把
    private let keyOverride: (@Sendable (Vendor) -> String?)?
    /// 最近一次请求被服务商退回的原因（模型名不对、地址不对、没开通）；之后成功了、换了设置就清掉。设置页拿它提示
    private let failure = Mutex<String?>(nil)
    public var lastFailure: String? { failure.withLock { $0 } }
    /// 被拒过的那把密钥：不再拿它发请求
    private let rejected = Mutex<String?>(nil)
    /// 这个实例发出的请求一共花了多少美元，按回答里的 usage.cost 累计（只有 OpenRouter 报）。手动跑的真实云端测试拿它核对花费
    private let cost = Mutex(0.0)
    var spent: Double { cost.withLock { $0 } }
    /// 模型的上下文长度：问到一次就记住
    private let context = Mutex<Int?>(nil)

    public init(_ setup: CloudSetup = CloudSetup(), session: URLSession = .shared, key: (@Sendable (Vendor) -> String?)? = nil) {
        self.session = session
        chosen = Mutex(setup)
        keyOverride = key
    }

    /// 这家的密钥：每家一把，分开存
    private func key(for vendor: Vendor) -> String? { keyOverride.map { $0(vendor) } ?? KeyFile.key(for: vendor.rawValue) }

    public var keyState: KeyState { keyState(for: setup.vendor) }

    private func keyState(for vendor: Vendor) -> KeyState {
        guard let key = key(for: vendor) else { return .missing }
        return key == rejected.withLock({ $0 }) ? .rejected : .ready
    }

    /// 密钥能用，而且知道发到哪、用哪个模型
    public var isReady: Bool {
        let setup = setup
        return keyState(for: setup.vendor) == .ready && setup.base != nil && setup.chosenModel != nil
    }

    public func setKey(_ key: String) throws { try KeyFile.setKey(key, for: setup.vendor.rawValue) }

    /// 换服务商、模型：之后的请求都按新的；上下文长度跟着模型走，要重新问。
    /// 换了地方，「这把密钥被拒过」就不作数了：可能只是上一个地址填错
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

    /// judging：用判断模型（没另填、这家也没有另外推荐的，就是同一个）
    func generate(_ prompt: String, images: [Data], careful: Bool, judging: Bool) async throws -> String {
        let setup = setup
        guard let model = judging ? setup.chosenJudgeModel : setup.chosenModel else { throw Unavailable.notReady }
        if setup.vendor.wire == .messages { return try await claudeGenerate(prompt, images: images, careful: careful, model: model) }
        let content: [[String: Any]] = [["type": "text", "text": prompt]] + images.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
        }
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": content]]]
        if setup.vendor.jsonMode { body["response_format"] = ["type": "json_object"] }
        // 平时关掉思考：省时间；判断把握不够时才让它想
        body.merge(setup.vendor.thinkingFields(on: careful)) { $1 }
        body.merge(setup.vendor.extras) { $1 }
        let response = try await post("chat/completions", body)
        guard let choices = response["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { throw Failure(message: String(localized: "\(displayed(name)) 没有返回内容")) }
        return text
    }

    /// 拿判断模型来生成：交给出口去冒充判断能力
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

    /// 发出请求，拿回状态正常的响应。流式和非流式共用：密钥被拒时记下这把；限流和服务端出错时等一会儿重试，最多三次。
    /// errorData 把出错时的响应读成完整的数据，好取出错误说明
    func send<Response>(_ path: String, _ body: [String: Any], headers: [String: String] = [:],
                        fetch: (URLRequest) async throws -> (Response, URLResponse),
                        errorData: (Response) async throws -> Data) async throws -> Response {
        // 服务商、地址、密钥取自同一刻的设置：正好赶上换服务商时，不会把这家的密钥发到那家去
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
            // 密钥不对：记下这把，卡片停在「等待密钥」，不逐张记失败
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

    /// 按回答里的 usage.cost 累计花费
    @discardableResult
    private func charge(_ usage: Any?) -> Double {
        guard let charge = ((usage as? [String: Any])?["cost"] as? NSNumber)?.doubleValue else { return 0 }
        cost.withLock { $0 += charge }
        return charge
    }
}

// MARK: 对话

extension Cloud: Conversation {
    /// 发出流式请求，拿回一行行到达的回答
    func stream(_ path: String, _ body: [String: Any], headers: [String: String] = [:]) async throws -> URLSession.AsyncBytes {
        try await send(path, body, headers: headers, fetch: { try await self.session.bytes(for: $0) }) { bytes in
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return data
        }
    }

    /// 从 OpenRouter 的模型列表里读上下文长度，读到一次就记住；别家没有这份列表，问不到
    public func contextLength() async -> Int? {
        if let known = context.withLock({ $0 }) { return known }
        let setup = setup
        guard setup.vendor == .openRouter, let model = setup.chosenModel, let (data, _) = try? await session.data(from: URL(string: "https://openrouter.ai/api/v1/models")!),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = json["data"] as? [[String: Any]],
              let length = (models.first { $0["id"] as? String == model }?["context_length"] as? NSNumber)?.intValue else { return nil }
        // 问的这会儿模型被换了，就不记
        if setup == self.setup { context.withLock { $0 = length } }
        return length
    }

    /// chat/completions 打开 stream：服务器一段段推回 SSE（每行「data: {…}」），文字边到边交出去；
    /// 工具调用的名字和参数是分好几段到的，拼齐了在结束前一起交出；最后一段带用量和花费
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
                        // 「: OPENROUTER PROCESSING」这类注释行是保活用的
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        if payload == "[DONE]" { break }
                        guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                        if let error = json["error"] as? [String: Any] { throw Failure(message: String(localized: "\(displayed(name))：\(error["message"] as? String ?? String(localized: "未知错误"))")) }
                        if let used = json["usage"] as? [String: Any] { usage = Self.usage(used, cost: charge(used)) }
                        guard let delta = ((json["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] else { continue }
                        // 想的内容：OpenRouter 放在 reasoning，别家放在 reasoning_content
                        if let thought = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String, !thought.isEmpty {
                            continuation.yield(.thought(thought))
                        }
                        if let text = delta["content"] as? String, !text.isEmpty { continuation.yield(.text(text)) }
                        for piece in delta["tool_calls"] as? [[String: Any]] ?? [] {
                            let i = (piece["index"] as? NSNumber)?.intValue ?? 0
                            var call = calls[i] ?? ToolCall(id: "", name: "", arguments: "")
                            if let id = piece["id"] as? String, !id.isEmpty { call.id = id }
                            // 有的服务商（Gemini）在调用上附一段凭据，下一轮要原样带回
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
        // 经 OpenRouter 用 Anthropic、Google 的模型要显式标缓存，别的（DeepSeek）自动按开头缓存
        let marks = setup.vendor == .openRouter && (model.hasPrefix("anthropic/") || model.hasPrefix("google/"))
        let messages: [[String: Any]] = chat.messages.enumerated().map { m, message in
            var out: [String: Any] = ["role": message.role.rawValue]
            switch message.role {
            case .system, .tool:
                out["content"] = message.text
            case .assistant:
                // 只调工具、不说话：内容留空
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
            // Claude 存下的是它自己的一整轮内容，不是能给别家看的文字
            if let thought = message.thought, setup.vendor.sendsThoughtsBack, Self.claudeTurn(thought) == nil { out["reasoning_content"] = thought }
            return out
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
        ]
        body.merge(setup.vendor.thinkingFields(on: setup.thinking)) { $1 }
        // 同 generate：OpenRouter 按最近的响应速度挑服务商。每轮可能落到不同服务商上，缓存命中率由测试集量（discussion-plan.md 第五节）
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
