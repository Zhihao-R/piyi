import Foundation

/// Jev：专做判断的云端模型，经 OpenRouter 转接，用同一把密钥。
/// 不写文字，直接给每个选项的概率；一次请求里的几道题同时答，搜一句话从 2.7 秒降到 1.3 秒。不能看图
public struct Jev: Judgment {
    public let name = "Jev"
    public let seesImages = false
    /// 只在主题筛选上试过：0.85 时最准，照搬 deepseek 的 0.75 要差一截
    public let sureEnough = 0.85
    static let model = "typesafe/jev-1.13"

    let cloud: Cloud

    public init(via cloud: Cloud) { self.cloud = cloud }

    /// 只有 OpenRouter 转接它；设置里另填了判断模型就不用它
    public var isReady: Bool { cloud.isReady && cloud.setup.usesJev }

    public func judge(_ facts: Facts, _ questions: [Question], images: [Data]) async throws -> [Verdict] {
        let ids = questions.indices.map { "q\($0)" }
        let response = try await cloud.post("systemone", [
            "model": Self.model,
            "state": Dictionary(facts.map { ($0.name, $0.text) }, uniquingKeysWith: { a, _ in a }),
            "questions": Dictionary(uniqueKeysWithValues: zip(ids, questions.map(Self.body))),
        ])
        guard let answers = response["answers"] as? [String: [String: Any]] else { throw MalformedReply() }
        return try zip(ids, questions).map { id, question in
            guard let answer = answers[id] else { throw MalformedReply() }
            return try Self.verdict(answer, for: question)
        }
    }

    static func body(_ question: Question) -> [String: Any] {
        switch question.answers {
        case .yesNo: ["type": "noul", "instructions": question.text]
        case .choice(let options):
            ["type": "choice", "instructions": question.text, "criteria": Dictionary(options.map { ($0.key, $0.text) }, uniquingKeysWith: { a, _ in a })]
        case .grade(let levels): ["type": "score", "instructions": question.text, "criteria": levels]
        }
    }

    /// 结论取概率最高的选项，把握就是它的概率（回答里另有一个 confidence，口径不同，选型时没用它定线）
    static func verdict(_ answer: [String: Any], for question: Question) throws -> Verdict {
        let probabilities: [Double]
        switch question.answers {
        case .yesNo:
            guard let yes = (answer["noul"] as? NSNumber)?.doubleValue else { throw MalformedReply() }
            probabilities = [yes, 1 - yes]
        case .choice(let options):
            guard let p = answer["probabilities"] as? [String: NSNumber] else { throw MalformedReply() }
            probabilities = options.map { p[$0.key]?.doubleValue ?? 0 }
        case .grade(let levels):
            guard let p = answer["probabilities"] as? [String: NSNumber] else { throw MalformedReply() }
            probabilities = levels.indices.map { p[String($0)]?.doubleValue ?? 0 }
        }
        guard let best = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) else { throw MalformedReply() }
        return Verdict(choice: best, confidence: probabilities[best])
    }
}
