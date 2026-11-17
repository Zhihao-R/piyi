import Foundation
import Library

// Claude uses Anthropic's own API (/v1/messages), a different format from everyone else's chat/completions:
// the system prompt goes separately, content is split into blocks, tool results count as the user speaking, and streamed answers arrive as events. This only converts between the two formats; requests still go through Cloud.send.

extension Cloud {
    private static let claudeVersion = "2026-10-21"
    /// These models may refuse for safety reasons: let the server automatically retry with another model, so one card doesn't just fail.
    /// Only models officially documented to support this are listed (Haiku isn't); other models may not accept the parameter
    private static let fallbackModels = ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    /// Headers and parameters sent with every request: API version, automatic model switch on refusal
    private func claudeBase(_ model: String, betas: [String] = []) -> (headers: [String: String], body: [String: Any]) {
        var (betas, body): ([String], [String: Any]) = (betas, ["model": model])
        if Self.fallbackModels.contains(model) {
            betas.append("server-side-fallback-2026-07-01")
            body["fallbacks"] = "default"
        }
        var headers = ["anthropic-version": Self.claudeVersion]
        if !betas.isEmpty { headers["anthropic-beta"] = betas.joined(separator: ",") }
        return (headers, body)
    }

    /// Newer Claude models can't turn thinking off; effort decides how much: normally the lowest level
    private static func effort(_ thinking: Bool) -> [String: Any] { ["effort": thinking ? "high" : "low"] }

    private static func image(_ data: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
    }

    func claudeGenerate(_ prompt: String, images: [Data], careful: Bool, model: String) async throws -> String {
        var (headers, body) = claudeBase(model)
        // This API requires an answer length cap. 16000 is the official recommendation for non-streaming requests: larger ones wait until they time out
        body["max_tokens"] = 16000
        body["output_config"] = Self.effort(careful)
        body["messages"] = [["role": "user", "content": images.map(Self.image) + [["type": "text", "text": prompt]]]]
        let response = try await post("messages", body, headers: headers)
        if response["stop_reason"] as? String == "refusal" { throw Failure(message: String(localized: "\(displayed(name)) 拒绝了这次请求")) }
        let text = (response["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw Failure(message: String(localized: "\(displayed(name)) 没有返回内容")) }
        return text
    }

    /// Streaming chat: the answer arrives as events, each content block numbered. Text is passed on as it arrives; tool calls and thinking are passed on once complete, before the end.
    /// Thinking carries a signature and must be sent back next round unchanged and in the original order, so this round's whole set of content blocks is stored as JSON as the thought
    func claudeConverse(_ chat: Chat, yield: (ChatChunk) -> Void) async throws {
        let setup = setup
        guard let model = setup.chosenModel else { throw Unavailable.notReady }
        // Cards on the desk change, so earlier content may not match what the model saw last time; when it doesn't, let the server drop the old thinking instead of erroring
        var (headers, body) = claudeBase(model, betas: ["thinking-binding-controls-2026-08-01"])
        body.merge(claudeBody(chat, thinking: setup.thinking)) { $1 }
        let bytes = try await stream("messages", body, headers: headers)
        var blocks: [Int: [String: Any]] = [:]
        var inputs: [Int: String] = [:]
        var usage = ChatUsage()
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "),
                  let event = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))) as? [String: Any] else { continue }
            let index = (event["index"] as? NSNumber)?.intValue ?? 0
            let int = { (value: Any?) in (value as? NSNumber)?.intValue ?? 0 }
            switch event["type"] as? String {
            case "error":
                throw Failure(message: String(localized: "\(displayed(name))：\((event["error"] as? [String: Any])?["message"] as? String ?? String(localized: "未知错误"))"))
            case "message_start":
                let used = (event["message"] as? [String: Any])?["usage"] as? [String: Any]
                usage.cached = int(used?["cache_read_input_tokens"])
                usage.input = int(used?["input_tokens"]) + usage.cached + int(used?["cache_creation_input_tokens"])
            case "content_block_start":
                blocks[index] = event["content_block"] as? [String: Any]
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], var block = blocks[index] else { continue }
                if let text = delta["text"] as? String {
                    block["text"] = (block["text"] as? String ?? "") + text
                    yield(.text(text))
                }
                if let thinking = delta["thinking"] as? String { block["thinking"] = (block["thinking"] as? String ?? "") + thinking }
                if let signature = delta["signature"] as? String { block["signature"] = signature }
                if let json = delta["partial_json"] as? String { inputs[index, default: ""] += json }
                blocks[index] = block
            case "message_delta":
                usage.output = int((event["usage"] as? [String: Any])?["output_tokens"])
                if (event["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" { throw Failure(message: String(localized: "\(displayed(name)) 拒绝了这次请求")) }
            default: break
            }
        }
        var content: [[String: Any]] = []
        for index in blocks.keys.sorted() {
            guard var block = blocks[index] else { continue }
            if block["type"] as? String == "tool_use" {
                let arguments = inputs[index].flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
                block["input"] = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) ?? [String: Any]()
                yield(.call(ToolCall(id: block["id"] as? String ?? "call_\(index)", name: block["name"] as? String ?? "", arguments: arguments)))
            }
            content.append(block)
        }
        let thought = content.contains { ($0["type"] as? String)?.contains("thinking") == true }
        if thought, let data = try? JSONSerialization.data(withJSONObject: [Self.claudeMark: content]) { yield(.thought(String(decoding: data, as: UTF8.self))) }
        yield(.done(usage))
    }

    /// A whole round's content stored in thought is wrapped under this name: other providers' thoughts are text, and this tells them apart
    private static let claudeMark = "claude"

    /// If thought holds a whole round of Claude content, take it out; if it's another provider's text, return nil
    static func claudeTurn(_ thought: String?) -> [[String: Any]]? {
        guard let thought, thought.hasPrefix("{\"\(claudeMark)\":"),
              let stored = (try? JSONSerialization.jsonObject(with: Data(thought.utf8))) as? [String: Any] else { return nil }
        return stored[claudeMark] as? [[String: Any]]
    }

    func claudeBody(_ chat: Chat, thinking: Bool) -> [String: Any] {
        var system: [String] = []
        var messages: [[String: Any]] = []
        // Consecutive turns from the same side are merged into one: tool results and the user's words right after them both count as the user's side
        func add(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if messages.last?["role"] as? String == role, let before = messages[messages.count - 1]["content"] as? [[String: Any]] {
                messages[messages.count - 1]["content"] = before + blocks
            } else {
                messages.append(["role": role, "content": blocks])
            }
        }
        for message in chat.messages {
            switch message.role {
            case .system:
                system.append(message.text)
            case .user:
                add("user", message.parts.map { part in
                    switch part {
                    case .text(let text): ["type": "text", "text": text]
                    case .image(let data): Self.image(data)
                    }
                })
            case .tool:
                add("user", [["type": "tool_result", "tool_use_id": message.callID ?? "", "content": message.text]])
            case .assistant:
                let kept = Set(message.calls.map(\.id))
                if let stored = Self.claudeTurn(message.thought) {
                    // Send that round's content back exactly as it was; only drop calls that never got a result
                    add("assistant", stored.filter { $0["type"] as? String != "tool_use" || kept.contains($0["id"] as? String ?? "") })
                } else {
                    add("assistant", (message.text.isEmpty ? [] : [["type": "text", "text": message.text]]) + message.calls.map {
                        ["type": "tool_use", "id": $0.id, "name": $0.name,
                         "input": (try? JSONSerialization.jsonObject(with: Data($0.arguments.utf8))) ?? [String: Any]()]
                    })
                }
            }
        }
        var body: [String: Any] = [
            "messages": messages,
            "stream": true,
            // This API requires an answer length cap. 64000 is the official recommendation for streaming requests; current models can all write up to 128000
            "max_tokens": 64000,
            "output_config": Self.effort(thinking),
            "thinking": ["type": "adaptive", "block_binding": ["prefix_mismatch_behavior": "drop_block"]],
            // The unchanging start is cached automatically
            "cache_control": ["type": "ephemeral"],
        ]
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if !chat.tools.isEmpty {
            body["tools"] = chat.tools.map { tool in
                ["name": tool.name, "description": tool.description,
                 "input_schema": (try? JSONSerialization.jsonObject(with: Data(tool.parameters.utf8))) ?? ["type": "object"]]
            }
            if !chat.toolsAllowed { body["tool_choice"] = ["type": "none"] }
        }
        return body
    }
}
