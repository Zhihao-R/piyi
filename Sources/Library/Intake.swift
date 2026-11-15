import Foundation
import CoreGraphics

/// 收了一批之后的回话：几样是新的，几样已经收过，几样没存进去。各入口的说法都在这里定，浏览器扩展显示的也是 App 发过去的这一句
public struct Receipt: Sendable, Equatable {
    public var new = 0
    public var existing = 0
    public var failed = 0

    public init(new: Int = 0, existing: Int = 0, failed: Int = 0) { (self.new, self.existing, self.failed) = (new, existing, failed) }

    /// 至少有一样在资料库里了；一样都没存好时不能说「收下了」，也不响那一声
    public var kept: Bool { new + existing > 0 }

    public var text: String { text(new: new > 1 ? String(localized: "已收进拼贴 \(new) 条") : String(localized: "已收进拼贴")) }

    /// 在浏览器里右键收的这一样，说出收的是什么：图片站的图常被透明层盖住，浏览器不认为右键在图上，会收成整页，看提示当场就知道
    public func text(taking source: Source) -> String {
        let said = switch source.kind {
        case .image: String(localized: "已收下这张图")
        case .text: String(localized: "已收下这段话")
        default: String(localized: "已收下这一页")
        }
        return text(new: said)
    }

    private func text(new said: String) -> String {
        guard kept else { return String(localized: "没存好，下次打开拼贴时再试") }
        let kept = switch (new, existing) {
        case (_, 0): said
        case (0, 1): String(localized: "已经收过，提到了最前")
        case (0, _): String(localized: "\(existing) 条都已经收过，提到了最前")
        default: String(localized: "已收进拼贴 \(new) 条，另有 \(existing) 条已经收过")
        }
        return failed > 0 ? kept + String(localized: "；有 \(failed) 条没存好，下次打开拼贴时再试") : kept
    }
}

/// 收集流程里不碰画布的几步，收集协调者和测试都走这里：
/// 1. 收的是网址，先按网址查重；收过的提到最前
/// 2. 没收过的写入占位卡（和它在画板上的摆放）
/// 3. 抽取内容，填进占位卡（按内容指纹、最终地址再查重），每一样填完就报一次
public struct Intake: Sendable {
    let store: Store
    let extractor: Extractor
    /// 同时抽取几样
    static let parallel = 4

    public init(store: Store, extractor: Extractor) {
        self.store = store
        self.extractor = extractor
    }

    /// 一样东西的去向
    public enum Outcome: Sendable {
        /// 新收的，内容已经填进这张卡
        case created(card: Int64, Material)
        /// 已经收过：提到了最前。restored 表示它原来在废纸篓里，placed 表示这次放进了目标画板
        case existing(Card, restored: Bool, placed: Bool)
        /// 抽取期间占位卡被删了：不用再收
        case gone
        /// 没存进资料库
        case failed
    }

    public enum Event: Sendable {
        /// 占位卡都写进去了
        case admitted
        /// 一样东西有了去向
        case settled(Source, Outcome)
        /// 每一样是新的还是收过的都清楚了，这时才好说「收下了」：收网址的在查重之后（占位卡已经带着网址存进资料库），其余的在内容填进去之后
        case judged(Receipt)
    }

    /// 收一批，board 为 nil 时只进资料库。frames 给去掉重复网址之后的每一样定一个落点；report 按发生的先后报进展。
    /// 交回每一样的去向
    public func collect(_ sources: [Source], on board: Int64? = nil,
                        frames: @Sendable ([Source]) -> [CGRect] = { $0.map { _ in .zero } },
                        report: @Sendable (Event) async -> Void = { _ in }) async throws -> [Outcome] {
        // 这一批里重复的网址只留一个
        var seen = Set<String>()
        let sources = sources.filter { source in source.url.flatMap { URLKey.of($0.absoluteString) }.map { seen.insert($0).inserted } ?? true }
        let frames = frames(sources)
        var outcomes = [Outcome](repeating: .failed, count: sources.count)
        var receipt = Receipt()

        // 1
        var fresh: [Int] = []
        for (i, source) in sources.enumerated() {
            guard let url = source.url, let existing = try await store.card(forURL: url.absoluteString) else { fresh.append(i); continue }
            outcomes[i] = try await reused(existing, on: board, frame: frames[i], note: source.note)
            receipt.existing += 1
            await report(.settled(source, outcomes[i]))
        }

        // 2
        var ids: [Int64] = []
        for i in fresh {
            let source = sources[i]
            ids.append(try await store.placeholder(source.kind, url: source.url?.absoluteString, sourceURL: source.page?.absoluteString,
                                                   note: source.note, title: source.url?.host(), on: board, frame: frames[i]))
        }
        if !fresh.isEmpty { await report(.admitted) }
        // 网址没查到就是新的；其余的要等内容填进去、按指纹查过才知道
        var unjudged = fresh.count { sources[$0].url == nil }
        receipt.new = fresh.count - unjudged
        if unjudged == 0 { await report(.judged(receipt)) }

        // 3
        await withTaskGroup(of: (Int, Outcome).self) { group in
            var next = 0
            func add() {
                let i = fresh[next], id = ids[next]
                group.addTask(priority: .userInitiated) { (i, await filled(id, from: sources[i], on: board, frame: frames[i])) }
                next += 1
            }
            while next < min(Self.parallel, fresh.count) { add() }
            for await (i, outcome) in group {
                outcomes[i] = outcome
                await report(.settled(sources[i], outcome))
                if sources[i].url == nil {
                    switch outcome {
                    case .created: receipt.new += 1
                    case .existing: receipt.existing += 1
                    case .failed: receipt.failed += 1
                    case .gone: break
                    }
                    unjudged -= 1
                    if unjudged == 0 { await report(.judged(receipt)) }
                }
                if next < fresh.count { add() }
            }
        }
        return outcomes
    }

    /// 这一批都存进了资料库：收件箱里的原件可以删了
    public static func saved(_ outcomes: [Outcome]) -> Bool {
        !outcomes.contains { if case .failed = $0 { true } else { false } }
    }

    private func filled(_ id: Int64, from source: Source, on board: Int64?, frame: CGRect) async -> Outcome {
        let m = await extractor.material(for: source)
        switch try? await store.fill(id, with: m) {
        case .filled?: return .created(card: id, m)
        // 占位卡的摆放已经转给已有那张时，不再放一份
        case .duplicate(let existing, let placed)?:
            guard case .existing(let card, let restored, let placedNow)? = try? await reused(existing, on: placed ? nil : board, frame: frame) else { return .failed }
            return .existing(card, restored: restored, placed: placed || placedNow)
        case .gone?: return .gone
        case nil: return .failed
        }
    }

    private func reused(_ existing: Card, on board: Int64?, frame: CGRect, note: String? = nil) async throws -> Outcome {
        guard case .existing(_, let restored, let placed) = try await store.reuse(existing, on: board, frame: frame, note: note) else { return .failed }
        return .existing(existing, restored: restored, placed: placed)
    }
}
