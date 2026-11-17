import Testing
import Foundation
import Synchronization
@testable import Library

/// Body completion: which cards get transcribed, and transcribed ones aren't transcribed again
@Suite struct CompleteBody {
    /// Fake transcription: records which files were transcribed
    final class FakeModels: ExtractionModels {
        let transcribed = Mutex<[String]>([])
        func verdict(on page: PageGlance) async -> PageVerdict? { nil }
        func rescue(_ page: PageGlance) async -> (title: String?, body: String)? { nil }
        func transcribe(_ file: URL) async -> [Cue]? {
            transcribed.withLock { $0.append(file.pathExtension) }
            return [Cue(start: 0, end: 2, text: "转出来的文字")]
        }
    }

    func collect(_ m: Material, _ store: Store) async throws -> Int64 {
        let board = try await store.createBoard("A").id!
        guard case .created(let id) = try await store.collect(m, into: board, frame: .zero) else { throw CancellationError() }
        return id
    }

    @Test func transcribesFilesOnce() async throws {
        let store = try temporaryStore()
        let models = FakeModels()
        let extractor = Extractor(models: models)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        try Data("假视频".utf8).write(to: file)
        var video = Material(kind: .video)
        video.original = file
        let id = try await collect(video, store)

        try await extractor.completeBody(of: id, in: store)
        #expect(try await store.card(id)?.transcript == "00:00 转出来的文字")
        // Completing again (refetching a direct video link) doesn't transcribe again
        try await extractor.completeBody(of: id, in: store)
        #expect(models.transcribed.withLock { $0 } == ["mp4"])

        // Platform videos have no file: only the description, no transcription
        var platform = Material(kind: .video)
        platform.body = "简介"
        platform.url = "https://www.bilibili.com/video/BV1xx411c7XX/"
        let other = try await collect(platform, store)
        try await extractor.completeBody(of: other, in: store)
        #expect(try await store.card(other)?.body == "简介")
        #expect(models.transcribed.withLock { $0.count } == 1)
    }
}
