import Foundation
import CoreGraphics

/// The reply after collecting a batch: how many are new, how many already collected, how many weren't saved. The wording for every entry point is set here; the browser extension also shows the line the app sends it
public struct Receipt: Sendable, Equatable {
    public var new = 0
    public var existing = 0
    public var failed = 0

    public init(new: Int = 0, existing: Int = 0, failed: Int = 0) { (self.new, self.existing, self.failed) = (new, existing, failed) }

    /// At least one is in the library; if none were saved it can't say "collected", and doesn't play the sound either
    public var kept: Bool { new + existing > 0 }

    public var text: String { text(new: new > 1 ? String(localized: "已收进片羽 \(new) 条") : String(localized: "已收进片羽")) }

    /// For one thing collected via right-click in the browser, say what was collected: images on image sites are often covered by a transparent layer, so the browser doesn't think the right-click was on an image and collects the whole page; the message makes that clear right away
    public func text(taking source: Source) -> String {
        let said = switch source.kind {
        case .image: String(localized: "已收下这张图")
        case .text: String(localized: "已收下这段话")
        default: String(localized: "已收下这一页")
        }
        return text(new: said)
    }

    private func text(new said: String) -> String {
        guard kept else { return String(localized: "没存好，下次打开片羽时再试") }
        let kept = switch (new, existing) {
        case (_, 0): said
        case (0, 1): String(localized: "已经收过，提到了最前")
        case (0, _): String(localized: "\(existing) 条都已经收过，提到了最前")
        default: String(localized: "已收进片羽 \(new) 条，另有 \(existing) 条已经收过")
        }
        return failed > 0 ? kept + String(localized: "；有 \(failed) 条没存好，下次打开片羽时再试") : kept
    }
}

/// The steps of collecting that don't touch the canvas; the collect coordinator and tests both go through here:
/// 1. For a URL, check duplicates by URL first; ones already collected are brought to the front
/// 2. Ones not yet collected get placeholder cards written (with their placements on the board)
/// 3. Extract content and fill it into the placeholder (checking duplicates again by content fingerprint and final address), reporting each as it's filled
public struct Intake: Sendable {
    let store: Store
    let extractor: Extractor
    /// How many to extract at once
    static let parallel = 4

    public init(store: Store, extractor: Extractor) {
        self.store = store
        self.extractor = extractor
    }

    /// Where one thing ended up
    public enum Outcome: Sendable {
        /// Newly collected, content already filled into this card
        case created(card: Int64, Material)
        /// Already collected: brought to the front. restored means it was in the trash, placed means it was put on the target board this time
        case existing(Card, restored: Bool, placed: Bool)
        /// The placeholder was deleted during extraction: no need to collect it
        case gone
        /// Not saved to the library
        case failed
    }

    public enum Event: Sendable {
        /// All placeholders have been written
        case admitted
        /// One thing has ended up somewhere
        case settled(Source, Outcome)
        /// Whether each one is new or already collected is now clear, so it's time to say "collected": for URLs that's after the duplicate check (the placeholder is already saved to the library with its URL), for the rest after content is filled in
        case judged(Receipt)
    }

    /// Collect a batch; with board nil it only goes into the library. frames gives each thing (after dropping duplicate URLs) a landing spot; report reports progress as it happens.
    /// Returns where each one ended up
    public func collect(_ sources: [Source], on board: Int64? = nil,
                        frames: @Sendable ([Source]) -> [CGRect] = { $0.map { _ in .zero } },
                        report: @Sendable (Event) async -> Void = { _ in }) async throws -> [Outcome] {
        // Keep only one of each duplicate URL in this batch
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
        // A URL not found is new; the rest are only known after content is filled in and checked by fingerprint
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

    /// The whole batch was saved to the library: the originals in the inbox can be deleted
    public static func saved(_ outcomes: [Outcome]) -> Bool {
        !outcomes.contains { if case .failed = $0 { true } else { false } }
    }

    private func filled(_ id: Int64, from source: Source, on board: Int64?, frame: CGRect) async -> Outcome {
        let m = await extractor.material(for: source)
        switch try? await store.fill(id, with: m) {
        case .filled?: return .created(card: id, m)
        // When the placeholder's placement was already handed to the existing card, don't place another copy
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
