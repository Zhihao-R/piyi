import Testing
import Foundation
import GRDB
@testable import Library

/// Transcripts are segmented by time, each segment starting with a timestamp; old transcripts are split out of the body
@Suite struct TranscriptTests {
    @Test func groupsCuesIntoTimedParagraphs() {
        let cues = [
            Cue(start: 0, end: 4, text: "让我们开始吧"),
            Cue(start: 4, end: 9, text: "什么是代理\n"),
            // Under 20 seconds: no new segment however long the pause
            Cue(start: 12, end: 21, text: "带有工具的循环模型"),
            // Past 20 seconds with a pause of over 1 second since the last sentence: new segment
            Cue(start: 22.5, end: 30, text: "安全带"),
            Cue(start: 30, end: 40, text: "  "),
            // Even without pauses or sentence breaks, a new segment at 45 seconds
            Cue(start: 40, end: 50, text: "线束通常就像一层，"),
            Cue(start: 50, end: 60, text: "围绕模型"),
            Cue(start: 67.5, end: 70, text: "下一段"),
        ]
        #expect(Transcript.text(cues) == """
            00:00 让我们开始吧 什么是代理 带有工具的循环模型
            00:22 安全带 线束通常就像一层，围绕模型
            01:07 下一段
            """)
        // End-of-sentence punctuation can also start a new segment
        #expect(Transcript.text([Cue(start: 0, end: 20, text: "First."), Cue(start: 20, end: 25, text: "Second")]) == "00:00 First.\n00:20 Second")
        #expect(Transcript.stamp(3723) == "1:02:03")
    }

    /// Timestamps are written the same way as description chapters: clickable to jump in the detail view
    @Test func stampsAreChapters() {
        let text = Transcript.text([Cue(start: 0, end: 30, text: "一"), Cue(start: 95, end: 100, text: "二")])
        #expect(Player.chapters(in: text, duration: 100).map(\.seconds) == [0, 95])
    }

    /// Upgrade: for transcribed cards, the last paragraph of the body is split out as the transcript; joined back it's the same as before, so the basis for understanding doesn't change
    @Test func migrationSplitsTranscriptOffBody() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "piyi-migrate-\(UUID().uuidString).sqlite").path
        let db = try DatabaseQueue(path: path)
        try Schema.migrator.migrate(db, upTo: "v9")
        let bodies: [(String?, Bool)] = [("简介\n\n第二段\n\n说的话 一句一句", true), ("只有转录", true), ("没转录\n\n的简介", false), (nil, false)]
        try db.write { db in
            for (body, transcribed) in bodies {
                try db.execute(sql: "INSERT INTO card (kind, collectedAt, extraction, tags, body, transcribed) VALUES ('video', '2026-01-01', 'complete', '[]', ?, ?)",
                               arguments: [body, transcribed])
            }
        }
        try Schema.migrator.migrate(db)
        let cards = try db.read { db in try Card.order(Column("id")).fetchAll(db) }
        #expect(cards.map(\.body) == ["简介\n\n第二段", nil, "没转录\n\n的简介", nil])
        #expect(cards.map(\.transcript) == ["说的话 一句一句", "只有转录", nil, nil])
        #expect(cards.map(\.fullBody) == bodies.map(\.0))
    }
}
