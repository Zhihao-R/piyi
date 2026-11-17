import Foundation

/// Jev: a cloud model made just for judging, routed through OpenRouter with the same key.
/// It writes no text, just gives each option a probability; several questions in one request are answered together, cutting a search sentence from 2.7 s to 1.3 s. Can't see images
public struct Jev: Judgment {
    public let name = "Jev"
    public let seesImages = false
    /// Only tried on topic filtering: most accurate at 0.85; reusing deepseek's 0.75 is noticeably worse
    public let sureEnough = 0.85
    static let model = "typesafe/jev-1.13"

    let cloud: Cloud

    public init(via cloud: Cloud) { self.cloud = cloud }

    /// Only OpenRouter routes it; not used if a separate judge model is entered in Settings
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

    /// The conclusion is the option with the highest probability, and the confidence is that probability (the answer also has a confidence field, measured differently; it wasn't used to set thresholds when choosing models)
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
