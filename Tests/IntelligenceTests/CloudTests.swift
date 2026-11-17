import Foundation
import Synchronization
import Testing
@testable import Library
@testable import Intelligence

/// How each provider's requests differ: mistakes here would only show up once actually connected to that provider
@Suite struct CloudTests {
    private func cloud(_ vendor: Vendor, thinking: Bool = false, address: String = "") -> Cloud {
        Cloud(CloudSetup(vendor: vendor, address: address, model: "m", thinking: thinking), key: { _ in "k" })
    }

    private let chat = Chat(messages: [
        .text(.user, "问"),
        ChatMessage(.assistant, [], calls: [ToolCall(id: "a", name: "search", arguments: "{}")], thought: "想过的"),
        ChatMessage(.tool, [.text("结果")], callID: "a"),
    ], tools: [])

    @Test func thinkingIsSpelledPerVendor() {
        #expect(Vendor.openRouter.thinkingFields(on: true) as NSDictionary == ["reasoning": ["enabled": true]])
        #expect(Vendor.deepSeek.thinkingFields(on: false) as NSDictionary == ["thinking": ["type": "disabled"]])
        #expect(Vendor.volcano.thinkingFields(on: true) as NSDictionary == ["thinking": ["type": "enabled"]])
        #expect(Vendor.bailian.thinkingFields(on: false) as NSDictionary == ["enable_thinking": false])
        // SiliconFlow only sends it when on; custom doesn't send it
        #expect(Vendor.siliconFlow.thinkingFields(on: false).isEmpty)
        #expect(Vendor.siliconFlow.thinkingFields(on: true) as NSDictionary == ["enable_thinking": true])
        #expect(Vendor.custom.thinkingFields(on: true).isEmpty)
        // For providers whose thinking can't be turned off, "off" is the lowest level
        #expect(Vendor.kimi.thinkingFields(on: false) as NSDictionary == ["reasoning_effort": "low"])
        #expect(Vendor.openAI.thinkingFields(on: false) as NSDictionary == ["reasoning_effort": "none"])
    }

    @Test func everyVendorButCustomWorksWithJustAKey() {
        for vendor in Vendor.allCases where vendor != .custom {
            #expect(Cloud(CloudSetup(vendor: vendor), key: { _ in "k" }).isReady, "\(vendor)")
        }
    }

    @Test func discussionFollowsTheThinkingSwitch() {
        #expect(cloud(.deepSeek, thinking: true).body(chat)["thinking"] as? [String: String] == ["type": "enabled"])
        #expect(cloud(.deepSeek).body(chat)["thinking"] as? [String: String] == ["type": "disabled"])
    }

    @Test func thoughtsGoBackOnlyWhereRequired() throws {
        func assistant(_ vendor: Vendor) throws -> [String: Any] {
            try #require((cloud(vendor, address: "https://a.example/v1").body(chat)["messages"] as? [[String: Any]])?[1])
        }
        #expect(try assistant(.deepSeek)["reasoning_content"] as? String == "想过的")
        #expect(try assistant(.kimi)["reasoning_content"] as? String == "想过的")
        #expect(try assistant(.bailian)["reasoning_content"] == nil)
    }

    @Test func whatVendorsAttachToCallsGoesBack() throws {
        let chat = Chat(messages: [ChatMessage(.assistant, [], calls: [ToolCall(id: "a", name: "f", arguments: "{}", extra: #"{"google":{"thought_signature":"s"}}"#)])], tools: [])
        func call(_ vendor: Vendor) throws -> [String: Any] {
            try #require(((cloud(vendor).body(chat)["messages"] as? [[String: Any]])?[0]["tool_calls"] as? [[String: Any]])?[0])
        }
        #expect(try call(.gemini)["extra_content"] as? NSDictionary == ["google": ["thought_signature": "s"]])
        #expect(try call(.deepSeek)["extra_content"] == nil)
    }

    @Test func rejectedKeyIsForgivenAfterMoving() {
        let setup = CloudSetup(vendor: .custom, address: "https://a.example/v1", model: "m")
        let cloud = Cloud(setup, key: { _ in "k" })
        var moved = setup
        moved.model = "n"
        cloud.configure(moved)
        #expect(cloud.keyState == .ready)
    }

    // MARK: Claude's API

    @Test func claudeGetsItsOwnShape() throws {
        let body = cloud(.anthropic, thinking: true).claudeBody(Chat(messages: [
            .text(.system, "规矩"),
            .text(.user, "问"),
            ChatMessage(.assistant, [.text("我查查")], calls: [ToolCall(id: "a", name: "search", arguments: #"{"q":"猫"}"#)]),
            ChatMessage(.tool, [.text("结果")], callID: "a"),
            .text(.user, "再说说"),
        ], tools: [ToolSpec(name: "search", description: "搜", parameters: #"{"type":"object"}"#)], toolsAllowed: false), thinking: true)
        #expect(body["system"] as? String == "规矩")
        #expect((body["output_config"] as? [String: String])?["effort"] == "high")
        #expect((body["tool_choice"] as? [String: String])?["type"] == "none")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let said = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(said.map { $0["type"] as? String } == ["text", "tool_use"])
        #expect((said[1]["input"] as? [String: String]) == ["q": "猫"])
        // A tool result and the message right after it are merged into one user message
        let back = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(back.map { $0["type"] as? String } == ["tool_result", "text"])
        #expect(back[0]["tool_use_id"] as? String == "a")
    }

    @Test func claudeThinkingGoesBackVerbatim() throws {
        let stored = #"{"claude":[{"type":"thinking","thinking":"","signature":"sig"},{"type":"tool_use","id":"a","name":"search","input":{}},{"type":"tool_use","id":"lost","name":"search","input":{}}]}"#
        let body = cloud(.anthropic).claudeBody(Chat(messages: [
            .text(.user, "问"),
            ChatMessage(.assistant, [], calls: [ToolCall(id: "a", name: "search", arguments: "{}")], thought: stored),
            ChatMessage(.tool, [.text("结果")], callID: "a"),
        ], tools: []), thinking: false)
        let said = try #require((body["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]])
        // The call that never got a result is dropped; the rest stays as is
        #expect(said.map { $0["type"] as? String } == ["thinking", "tool_use"])
        #expect(said[0]["signature"] as? String == "sig")
        // Switching to another provider mid-conversation: this part isn't text, so it isn't sent as thinking content
        let chat = Chat(messages: [ChatMessage(.assistant, [.text("答")], thought: stored)], tools: [])
        #expect((self.cloud(.deepSeek).body(chat)["messages"] as? [[String: Any]])?[0]["reasoning_content"] == nil)
        // The other way round, another provider's text going to Claude: this turn is assembled as usual, nothing dropped
        let turn = cloud(.anthropic).claudeBody(Chat(messages: [.text(.user, "问"), ChatMessage(.assistant, [.text("答")], thought: "[]")], tools: []), thinking: false)
        #expect((turn["messages"] as? [[String: Any]])?.count == 2)
    }

    @Test func onlyOpenRouterGetsItsOwnParameters() {
        #expect(cloud(.openRouter).body(chat)["provider"] != nil)
        #expect(cloud(.deepSeek).body(chat)["provider"] == nil)
        #expect(cloud(.volcano).body(chat)["stream_options"] != nil)
        #expect(cloud(.openRouter).body(chat)["stream_options"] == nil)
    }

    @Test func customAddressIsTidied() {
        let base = { CloudSetup(vendor: .custom, address: $0).base?.absoluteString }
        #expect(base("https://a.example/v1/") == "https://a.example/v1")
        #expect(base(" https://a.example/v1/chat/completions ") == "https://a.example/v1")
        #expect(base("a.example") == nil)
        #expect(base("") == nil)
    }

    @Test func customNeedsModelAndAddress() {
        #expect(!Cloud(CloudSetup(vendor: .custom, address: "https://a.example/v1"), key: { _ in "k" }).isReady)
        #expect(!cloud(.custom).isReady)
        #expect(cloud(.custom, address: "https://a.example/v1").isReady)
    }

    @Test func jevIsTheDefaultJudgeOnOpenRouterOnly() {
        #expect(Jev(via: cloud(.openRouter)).isReady)
        #expect(!Jev(via: cloud(.deepSeek)).isReady)
        // With a separate judgment model set, it isn't used
        #expect(!Jev(via: Cloud(CloudSetup(judgeModel: "google/gemini-4-hydrogen"), key: { _ in "k" })).isReady)
        #expect(CloudSetup(vendor: .openAI).chosenJudgeModel == "gpt-6-luna")
        #expect(CloudSetup(vendor: .deepSeek).chosenJudgeModel == "deepseek-flash")
        #expect(CloudSetup(vendor: .deepSeek, judgeModel: "x").chosenJudgeModel == "x")
    }

    @Test func judgingUsesTheJudgeModelWhenGiven() async throws {
        let models = Mutex<[String]>([])
        let judge = FakeGeneration { models.withLock { $0.append("判断") }; return #"{"choice":1,"confidence":0.9}"# }
        let writer = FakeGeneration { models.withLock { $0.append("生成") }; return "{}" }
        let gateway = Gateway(embedder: nil, generators: [writer], judging: [judge])
        _ = try await gateway.judge([], [Question("是吗", .yesNo)])
        #expect(models.withLock { $0 } == ["判断"])
    }
}

private struct FakeGeneration: Generation {
    let name = "假生成", isReady = true
    let reply: @Sendable () -> String
    func generate(_ prompt: String, images: [Data], careful: Bool) async throws -> String { reply() }
}

/// Thinking content is saved with the discussion record; records saved before this field was added still read fine
@Suite struct ThoughtRecordTests {
    @Test func thoughtsSurviveStorage() throws {
        let call = ToolCall(id: "a", name: "search", arguments: "{}")
        let calls = Happening.calls(said: "", thought: "想过的", [call])
        #expect(try Happening(kind: "calls", content: calls.content()) == calls)
        let answer = Happening.answer(Answer(text: "答", citations: [], thought: "想过的"))
        #expect(try Happening(kind: "answer", content: answer.content()) == answer)
    }

    @Test func recordsFromBeforeStillLoad() throws {
        #expect(try Happening(kind: "answer", content: #"{"text":"答","citations":[]}"#) == .answer(Answer(text: "答", citations: [])))
        #expect(try Happening(kind: "calls", content: #"{"said":"","calls":[]}"#) == .calls(said: "", []))
    }
}
