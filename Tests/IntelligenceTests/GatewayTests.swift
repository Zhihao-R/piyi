import Testing
import Foundation
import CoreGraphics
import ImageIO
import Synchronization
@testable import Intelligence
@testable import Library

/// 记录调用的假云端服务方：生成和判断都由它来
final class FakeCloud: Generation, Sendable {
    let name = "假云端"
    let calls = Mutex<[String]>([])
    let ready = Mutex(true)
    var isReady: Bool { ready.withLock { $0 } }

    func generate(_ prompt: String, images: [Data], careful: Bool) async throws -> String {
        calls.withLock { $0.append(prompt) }
        if prompt.contains("判断它属于哪一种") { return #"{"choice": 1, "confidence": 0.9}"# }
        if prompt.contains("找出这篇内容的标题和正文") { return #"{"title": "兜底标题", "body": "\#(String(repeating: "正文", count: 150))"}"# }
        return #"{"title":"假标题","caption":"假描述","detail":"假的详细描述","tags":["甲","乙"]}"#
    }
}

/// 假本机向量：按文字长度给一个固定向量，不用模型文件
struct FakeLocalEmbedder: Embedding {
    let name = "假本机", isReady = true, model = "fake-embedding"
    func embed(_ text: String, as role: EmbeddingRole) async throws -> [Float] { [Float(text.count % 7), 1, 0] }
}

func temporaryStore() throws -> Store {
    try Store(root: FileManager.default.temporaryDirectory.appending(path: "collage-test-\(UUID().uuidString)"))
}

/// 收一张网页卡（内容已经抽好）
func collectPage(_ store: Store, url: String, body: String = "一段正文") async throws -> Int64 {
    var m = Material(kind: .web)
    m.url = url
    m.title = "原标题"
    m.body = body
    let board = try await store.createBoard("A").id!
    guard case .created(let id) = try await store.collect(m, into: board, frame: .zero) else { throw CancellationError() }
    return id
}

@Suite struct Queue {
    @Test func waitsForKeyThenCatchesUp() async throws {
        let store = try temporaryStore()
        let cloud = FakeCloud()
        cloud.ready.withLock { $0 = false }
        let understander = Understander(store: store, gateway: Gateway(embedder: FakeLocalEmbedder(), generators: [cloud])) {}
        let id = try await collectPage(store, url: "https://example.com/a")

        await understander.run()
        #expect(try await store.card(id)?.understanding == .waitingKey)
        let before = try #require(try await store.vectorBases()[id])

        cloud.ready.withLock { $0 = true }
        await understander.run()
        let card = try #require(try await store.card(id))
        #expect(card.understanding == nil && card.caption == "假描述")
        // 描述生成出来后，算向量的文字变了，向量重算
        #expect(try await store.vectorBases()[id]?.basis != before.basis)
    }

    @Test func doneCardsAreNotRedone() async throws {
        let store = try temporaryStore()
        let cloud = FakeCloud()
        let understander = Understander(store: store, gateway: Gateway(embedder: FakeLocalEmbedder(), generators: [cloud])) {}
        _ = try await collectPage(store, url: "https://example.com/a")
        await understander.run()
        await understander.run()
        #expect(cloud.calls.withLock { $0.count } == 1)
    }

    @Test func refetchedContentIsUnderstoodAgain() async throws {
        let store = try temporaryStore()
        let cloud = FakeCloud()
        let understander = Understander(store: store, gateway: Gateway(embedder: FakeLocalEmbedder(), generators: [cloud])) {}
        let id = try await collectPage(store, url: "https://example.com/a")
        await understander.run()
        var m = Material(kind: .web)
        m.url = "https://example.com/a"
        m.title = "原标题"
        m.body = "补抓回来的完整正文"
        _ = try await store.fill(id, with: m)
        await understander.run()
        #expect(cloud.calls.withLock { $0.count } == 2)
    }

    /// 失败的卡不自动重试：只补颜色那一步不清掉失败原因
    @Test func failedCardsWaitForRetry() async throws {
        final class Broken: Generation, Sendable {
            let name = "坏", isReady = true
            let calls = Mutex(0)
            func generate(_ prompt: String, images: [Data], careful: Bool) async throws -> String { calls.withLock { $0 += 1 }; return "不是 JSON" }
        }
        let store = try temporaryStore()
        let broken = Broken()
        let understander = Understander(store: store, gateway: Gateway(embedder: FakeLocalEmbedder(), generators: [broken])) {}
        let board = try await store.createBoard("A").id!
        guard case .created(let id) = try await store.collect(FileExtractor.image(pngData()), into: board, frame: .zero) else { return }
        await understander.run()
        try await Task.sleep(for: .milliseconds(100))
        await understander.run()
        await understander.run()
        #expect(broken.calls.withLock { $0 } == 1)
        #expect(try await store.card(id)?.understandError != nil)
        try await store.retryFailedUnderstanding()
        await understander.run()
        #expect(broken.calls.withLock { $0 } == 2)
    }

    @Test func longContentGetsSummary() async throws {
        var card = Card(kind: .web)
        card.body = String(repeating: "字", count: Prompt.summaryLength)
        #expect(Prompt.needsSummary(card))
        #expect(Prompt.summary(["一", "二"], for: card) == "· 一\n· 二")
        #expect(Prompt.summary(["一"], for: card, whole: false) == "只读了前一部分\n· 一")
        card.kind = .video
        #expect(Prompt.summary(["一"], for: card)?.hasPrefix("仅根据简介") == true)
        card.body = "短"
        #expect(!Prompt.needsSummary(card))
    }

    /// 要点读全文：每一段都交给模型，模型抄的原话在哪一段里，那一段就是依据；抄错了找不到的没有依据
    @Test func summaryReadsEveryPassage() async throws {
        var card = Card(kind: .web)
        card.body = (1...40).map { "第 \($0) 段" + String(repeating: "字", count: 100) }.joined(separator: "\n")
        let passages = Passages.of(card)
        let asking = Prompt.summarizing(card, passages: passages)
        #expect(asking.whole)
        #expect(asking.prompt.contains("第 40 段"))
        let reply = Prompt.Points(points: [.init(text: "开头", quote: "第 1 段字字字"), .init(text: "结尾", quote: " 第 40 段字字 "), .init(text: "没依据", quote: "原文里没有的一句话")])
        let made = Prompt.summary(reply, passages: passages, whole: true, for: card)
        #expect(made.text == "· 开头\n· 结尾\n· 没依据")
        #expect(made.anchors == [SummaryAnchor(part: .body, quote: passages[0].text), SummaryAnchor(part: .body, quote: passages[39].text), nil])
        // 超过上限的只读前面，并标明
        card.body = (1...30).map { _ in String(repeating: "字", count: 5000) }.joined(separator: "\n")
        #expect(!Prompt.summarizing(card, passages: Passages.of(card)).whole)
        // 没换行的超长文字只有一段：截到上限，不是一个字都不给
        card.body = String(repeating: "字", count: Prompt.summaryInput + 10)
        let long = Prompt.summarizing(card, passages: Passages.of(card))
        #expect(!long.whole)
        #expect(long.prompt.count > Prompt.summaryInput)
    }
}

@Suite struct Judging {
    /// 假判断服务方：每条都答「是」，题目里带「拿不准」的把握只有 0.3；不能看图
    final class Unsure: Judgment, Sendable {
        let name = "假判断", isReady = true, seesImages = false, sureEnough = 0.85
        let calls = Mutex(0)
        func judge(_ facts: Facts, _ questions: [Question], images: [Data]) async throws -> [Verdict] {
            calls.withLock { $0 += 1 }
            return questions.map { Verdict(choice: 0, confidence: $0.text.contains("拿不准") ? 0.3 : 0.95) }
        }
    }

    /// 只有要求复判时，把握不够的那几条才交给生成能力仔细想一次；默认不复判
    @Test func onlyUnsureItemsAreRecheckedWhenAsked() async throws {
        let cloud = FakeCloud(), judge = Unsure()
        let gateway = Gateway(embedder: nil, generators: [cloud], judges: [judge])
        let question = Question("判断它属于哪一种", .yesNo)
        let plain = try await gateway.judge(each: ["有把握", "拿不准"], question)
        #expect(plain.map(\.confidence) == [0.95, 0.3])
        #expect(cloud.calls.withLock { $0.isEmpty })
        let rechecked = try await gateway.judge(each: ["有把握", "拿不准"], question, recheck: true)
        #expect(rechecked == [Verdict(choice: 0, confidence: 0.95), Verdict(choice: 0, confidence: 0.9)])
        #expect(cloud.calls.withLock { $0.count } == 1)
    }

    /// 几道题一次请求问完；有附图时交给能看图的生成能力
    @Test func imagesGoToJudgesThatSeeThem() async throws {
        let cloud = FakeCloud(), judge = Unsure()
        let gateway = Gateway(embedder: nil, generators: [cloud], judges: [judge])
        let questions = [Question("甲？", .yesNo), Question("乙？", .grade(["低", "高"]))]
        #expect(try await gateway.judge([("内容", "一句话")], questions).count == 2)
        #expect(judge.calls.withLock { $0 } == 1)
        _ = try? await gateway.judge(each: ["卡片"], Question("判断它属于哪一种", .yesNo), images: [Data([1])])
        #expect(judge.calls.withLock { $0 } == 1)
        #expect(cloud.calls.withLock { $0.count } == 1)
    }

    /// 前一家判断服务方出错，换下一家（Jev 出错时退到生成模型），不直接放弃
    @Test func failingJudgeFallsBackToTheNext() async throws {
        final class Broken: Judgment, Sendable {
            let name = "坏的", isReady = true, seesImages = false, sureEnough = 0.85
            func judge(_ facts: Facts, _ questions: [Question], images: [Data]) async throws -> [Verdict] { throw MalformedReply() }
        }
        let cloud = FakeCloud()
        let gateway = Gateway(embedder: nil, generators: [cloud], judges: [Broken()])
        let verdicts = try await gateway.judge([], [Question("判断它属于哪一种", .yesNo)])
        #expect(verdicts == [Verdict(choice: 0, confidence: 0.9)])
        #expect(cloud.calls.withLock { $0.count } == 1)
    }

    /// 不退到生成模型时，专门的判断服务方出错就直接报错（分拣只认 Jev 的概率）
    @Test func noFallbackAsksOnlyDedicatedJudges() async throws {
        final class Broken: Judgment, Sendable {
            let name = "坏的", isReady = true, seesImages = false, sureEnough = 0.85
            func judge(_ facts: Facts, _ questions: [Question], images: [Data]) async throws -> [Verdict] { throw MalformedReply() }
        }
        let cloud = FakeCloud()
        let gateway = Gateway(embedder: nil, generators: [cloud], judges: [Broken()])
        await #expect(throws: MalformedReply.self) { try await gateway.judge([], [Question("判断它属于哪一种", .yesNo)], fallback: false) }
        #expect(cloud.calls.withLock { $0 }.isEmpty)
    }

    /// Jev 的请求和回答：是或否、并列选项、等级三种题
    @Test func jevRequestsAndAnswers() throws {
        let choice = Question("哪种？", .choice([("content", "正常页"), ("login", "登录页")]))
        #expect(Jev.body(choice)["type"] as? String == "choice")
        #expect(Jev.body(choice)["criteria"] as? [String: String] == ["content": "正常页", "login": "登录页"])
        #expect(Jev.body(Question("是吗？", .yesNo))["type"] as? String == "noul")
        #expect(Jev.body(Question("多相关？", .grade(["无关", "相关"])))["criteria"] as? [String] == ["无关", "相关"])

        #expect(try Jev.verdict(["noul": 0.2], for: Question("是吗？", .yesNo)) == Verdict(choice: 1, confidence: 0.8))
        #expect(try Jev.verdict(["choice": "login", "probabilities": ["content": 0.3, "login": 0.7], "confidence": 0.4], for: choice)
                == Verdict(choice: 1, confidence: 0.7))
        #expect(try Jev.verdict(["probabilities": ["0": 0.1, "1": 0.2, "2": 0.6, "3": 0.1]], for: Question("多相关？", .grade(Searcher.relevance)))
                == Verdict(choice: 2, confidence: 0.6))
        #expect(throws: MalformedReply.self) { try Jev.verdict([:], for: choice) }
    }
}

/// 真实云端：只在手动给了 OPENROUTER_API_KEY 时跑，发一次请求，确认请求格式和回答解析是对的
@Suite struct RealCloud {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil))
    func understandsOneImage() async throws {
        let store = try temporaryStore()
        let seed = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/Collage/Resources/Seed/images").standardized
        let file = try #require(try FileManager.default.contentsOfDirectory(at: seed, includingPropertiesForKeys: nil).first { $0.pathExtension == "jpg" })
        let board = try await store.createBoard("A").id!
        guard case .created(let id) = try await store.collect(FileExtractor.image(try Data(contentsOf: file)), into: board, frame: .zero) else { return }
        let cloud = Cloud(key: { _ in ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] })
        await Understander(store: store, gateway: Gateway(embedder: FakeLocalEmbedder(), generators: [cloud])) {}.run()
        let card = try #require(try await store.card(id))
        #expect(card.understandError == nil)
        #expect(card.caption?.isEmpty == false && card.generatedTitle?.isEmpty == false && !card.tags.isEmpty)
        print("真实云端：", card.generatedTitle ?? "", "｜", card.caption ?? "", "｜", card.tags)
    }
}

/// 一张有颜色的小 PNG
func pngData() -> Data {
    let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}
