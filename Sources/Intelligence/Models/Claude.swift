import Foundation
import Library

// Claude 用 Anthropic 自己的接口（/v1/messages），和别家的 chat/completions 不是一种格式：
// 系统提示单独放、内容分成一块块、工具结果算用户说的话、流式回答按事件到达。这里只做两种格式之间的转换，发请求还是走 Cloud.send。

extension Cloud {
    private static let claudeVersion = "2026-10-21"
    /// 这几个模型可能因安全策略拒答：让服务端自动换一个模型重答，免得一张卡就此失败。
    /// 只列官方写明支持这项功能的型号（Haiku 没有），别的型号发了这个参数未必认
    private static let fallbackModels = ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    /// 每次请求都带的头和参数：接口版本、拒答时自动换模型
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

    /// 新的 Claude 关不掉思考，想多少由 effort 定：平时用最低一档
    private static func effort(_ thinking: Bool) -> [String: Any] { ["effort": thinking ? "high" : "low"] }

    private static func image(_ data: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
    }

    func claudeGenerate(_ prompt: String, images: [Data], careful: Bool, model: String) async throws -> String {
        var (headers, body) = claudeBase(model)
        // 这个接口必须给回答长度上限。16000 是官方给不流式请求的建议值：再大会等到超时
        body["max_tokens"] = 16000
        body["output_config"] = Self.effort(careful)
        body["messages"] = [["role": "user", "content": images.map(Self.image) + [["type": "text", "text": prompt]]]]
        let response = try await post("messages", body, headers: headers)
        if response["stop_reason"] as? String == "refusal" { throw Failure(message: String(localized: "\(displayed(name)) 拒绝了这次请求")) }
        let text = (response["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw Failure(message: String(localized: "\(displayed(name)) 没有返回内容")) }
        return text
    }

    /// 流式对话：回答按事件到达，一块块内容各有编号。文字边到边交出去；工具调用和想的内容拼齐了在结束前交出。
    /// 想的内容带着签名，下一轮必须原样、按原来的顺序交回，所以把这一轮的全部内容块存成 JSON 当作 thought
    func claudeConverse(_ chat: Chat, yield: (ChatChunk) -> Void) async throws {
        let setup = setup
        guard let model = setup.chosenModel else { throw Unavailable.notReady }
        // 桌上的卡会变，前面的内容和模型上次看到的可能对不上；对不上时让服务端丢掉旧的思考，不报错
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

    /// 存进 thought 的一整轮内容外面套一层这个名字：别家的 thought 是文字，靠它分得开
    private static let claudeMark = "claude"

    /// thought 里存的若是 Claude 的一整轮内容，取出来；是别家的文字就返回 nil
    static func claudeTurn(_ thought: String?) -> [[String: Any]]? {
        guard let thought, thought.hasPrefix("{\"\(claudeMark)\":"),
              let stored = (try? JSONSerialization.jsonObject(with: Data(thought.utf8))) as? [String: Any] else { return nil }
        return stored[claudeMark] as? [[String: Any]]
    }

    func claudeBody(_ chat: Chat, thinking: Bool) -> [String: Any] {
        var system: [String] = []
        var messages: [[String: Any]] = []
        // 同一方连着说的并成一条：工具结果和紧跟着的用户的话都算用户这一方
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
                    // 这一轮当时的内容原样交回；只去掉没等到结果的调用
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
            // 这个接口必须给回答长度上限。64000 是官方给流式请求的建议值，现在的型号都能写到 128000
            "max_tokens": 64000,
            "output_config": Self.effort(thinking),
            "thinking": ["type": "adaptive", "block_binding": ["prefix_mismatch_behavior": "drop_block"]],
            // 开头不变的部分自动缓存
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
