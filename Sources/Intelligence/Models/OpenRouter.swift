import Foundation
import Synchronization
import Library

/// OpenRouter：一个转接多家云端大模型的服务。生成直接用它；判断用它转接的 Jev（见 Jev.swift），共用这把密钥。
/// 用系统自带的网络接口直接发
public final class OpenRouter: Generation, Keyed {
    public let name = "OpenRouter"
    /// 看图写描述、判断、兜底都用它
    public static let defaultModel = "deepseek/deepseek-v4.1-flash"
    /// 搜索的速度测试里换别的模型比较
    let model: String

    let session: URLSession
    /// 密钥从哪读：平时是密钥文件，手动跑的真实云端测试从环境变量读
    private let key: @Sendable () -> String?
    /// 被拒过的那把密钥：不再拿它发请求
    private let rejected = Mutex<String?>(nil)
    /// 这个实例发出的请求一共花了多少美元，按回答里的 usage.cost 累计。手动跑的真实云端测试拿它核对花费
    private let cost = Mutex(0.0)
    var spent: Double { cost.withLock { $0 } }
    /// 模型的上下文长度：问到一次就记住
    private let context = Mutex<Int?>(nil)

    public init(session: URLSession = .shared, model: String = OpenRouter.defaultModel, key: (@Sendable () -> String?)? = nil) {
        self.session = session
        self.model = model
        self.key = key ?? { KeyFile.key(for: "OpenRouter") }
    }

    public var keyState: KeyState {
        guard let key = key() else { return .missing }
        return key == rejected.withLock({ $0 }) ? .rejected : .ready
    }

    public var isReady: Bool { keyState == .ready }

    public func setKey(_ key: String) throws { try KeyFile.setKey(key, for: name) }

    public struct Failure: LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    public func generate(_ prompt: String, images: [Data], careful: Bool) async throws -> String {
        let content: [[String: Any]] = [["type": "text", "text": prompt]] + images.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
        }
        let response = try await post("chat/completions", [
            "model": model,
            "messages": [["role": "user", "content": content]],
            "max_tokens": careful ? 4000 : 1200,
            "response_format": ["type": "json_object"],
            // 平时关掉思考：省时间，也免得额度全花在思考上；判断把握不够时才让它想
            "reasoning": ["enabled": careful],
            // 同一个模型有几十家服务商，默认按价格挑，常落到慢的那几家；按最近的响应速度挑，一次判断从 3 秒左右降到 1.7 秒左右。
            // 后台理解卡片也这样挑（有意的：自用阶段，单价最多贵一倍，一张卡仍不到一分钱）
            "provider": ["sort": "latency"],
        ])
        guard let choices = response["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { throw Failure(message: String(localized: "OpenRouter 没有返回内容")) }
        return text
    }

    func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let data = try await send(path, body, fetch: { try await self.session.data(for: $0) }, errorData: { $0 })
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = json["error"] as? [String: Any] { throw Failure(message: String(localized: "OpenRouter：\(error["message"] as? String ?? String(localized: "未知错误"))")) }
        charge(json["usage"])
        return json
    }

    /// 发出请求，拿回状态正常的响应。流式和非流式共用：密钥被拒时记下这把；限流和服务端出错时等一会儿重试，最多三次。
    /// errorData 把出错时的响应读成完整的数据，好取出错误说明
    private func send<Response>(_ path: String, _ body: [String: Any], fetch: (URLRequest) async throws -> (Response, URLResponse),
                                errorData: (Response) async throws -> Data) async throws -> Response {
        guard let key = key(), key != rejected.withLock({ $0 }) else { throw Unavailable.notReady }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/" + path)!, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Collage", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var lastError: Error = Failure(message: String(localized: "OpenRouter 请求失败"))
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt))) }
            let (response, http): (Response, URLResponse)
            do { (response, http) = try await fetch(request) } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                lastError = error
                continue
            }
            let status = (http as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return response }
            // 密钥不对：记下这把，卡片停在「等待密钥」，不逐张记失败
            if status == 401 {
                rejected.withLock { $0 = key }
                throw Unavailable.notReady
            }
            let json = (try? JSONSerialization.jsonObject(with: try await errorData(response))) as? [String: Any] ?? [:]
            lastError = Failure(message: "OpenRouter：\((json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)")")
            guard status == 429 || status >= 500 else { throw lastError }
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

extension OpenRouter: Conversation {
    /// 从模型列表里读上下文长度，读到一次就记住
    public func contextLength() async -> Int? {
        if let known = context.withLock({ $0 }) { return known }
        guard let (data, _) = try? await session.data(from: URL(string: "https://openrouter.ai/api/v1/models")!),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = json["data"] as? [[String: Any]],
              let length = (models.first { $0["id"] as? String == model }?["context_length"] as? NSNumber)?.intValue else { return nil }
        context.withLock { $0 = length }
        return length
    }

    /// chat/completions 打开 stream：服务器一段段推回 SSE（每行「data: {…}」），文字边到边交出去；
    /// 工具调用的名字和参数是分好几段到的，拼齐了在结束前一起交出；最后一段带用量和花费
    public func converse(_ chat: Chat) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await send("chat/completions", body(chat), fetch: { try await self.session.bytes(for: $0) }) { bytes in
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        return data
                    }
                    var calls: [Int: ToolCall] = [:]
                    var usage = ChatUsage()
                    for try await line in bytes.lines {
                        // 「: OPENROUTER PROCESSING」这类注释行是保活用的
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        if payload == "[DONE]" { break }
                        guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                        if let error = json["error"] as? [String: Any] { throw Failure(message: String(localized: "OpenRouter：\(error["message"] as? String ?? String(localized: "未知错误"))")) }
                        if let used = json["usage"] as? [String: Any] { usage = Self.usage(used, cost: charge(used)) }
                        guard let delta = ((json["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] else { continue }
                        if let text = delta["content"] as? String, !text.isEmpty { continuation.yield(.text(text)) }
                        for piece in delta["tool_calls"] as? [[String: Any]] ?? [] {
                            let i = (piece["index"] as? NSNumber)?.intValue ?? 0
                            var call = calls[i] ?? ToolCall(id: "", name: "", arguments: "")
                            if let id = piece["id"] as? String, !id.isEmpty { call.id = id }
                            let function = piece["function"] as? [String: Any]
                            if let name = function?["name"] as? String { call.name += name }
                            if let arguments = function?["arguments"] as? String { call.arguments += arguments }
                            calls[i] = call
                        }
                    }
                    for (i, call) in calls.sorted(by: { $0.key < $1.key }) {
                        continuation.yield(.call(call.id.isEmpty ? ToolCall(id: "call_\(i)", name: call.name, arguments: call.arguments) : call))
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
        // 只有 Anthropic、Google 的模型要显式标缓存，别家（DeepSeek）自动按开头缓存
        let marks = model.hasPrefix("anthropic/") || model.hasPrefix("google/")
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
                out["tool_calls"] = message.calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
            }
            if let id = message.callID { out["tool_call_id"] = id }
            return out
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "max_tokens": 4000,
            "reasoning": ["enabled": false],
            // 同 generate：按最近的响应速度挑服务商。每轮可能落到不同服务商上，缓存命中率由测试集量
            "provider": ["sort": "latency"],
        ]
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
