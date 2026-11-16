import Testing
import Foundation
import GRDB
@testable import Library

/// 转录按时间分段、段首带时间点；旧的转录从正文里分出来
@Suite struct TranscriptTests {
    @Test func groupsCuesIntoTimedParagraphs() {
        let cues = [
            Cue(start: 0, end: 4, text: "让我们开始吧"),
            Cue(start: 4, end: 9, text: "什么是代理\n"),
            // 不到 20 秒：停顿再久也不另起
            Cue(start: 12, end: 21, text: "带有工具的循环模型"),
            // 过了 20 秒、和上一句之间停了 1 秒以上：另起
            Cue(start: 22.5, end: 30, text: "安全带"),
            Cue(start: 30, end: 40, text: "  "),
            // 一直不停也不断句，到 45 秒另起
            Cue(start: 40, end: 50, text: "线束通常就像一层，"),
            Cue(start: 50, end: 60, text: "围绕模型"),
            Cue(start: 67.5, end: 70, text: "下一段"),
        ]
        #expect(Transcript.text(cues) == """
            00:00 让我们开始吧 什么是代理 带有工具的循环模型
            00:22 安全带 线束通常就像一层，围绕模型
            01:07 下一段
            """)
        // 句末标点也能另起
        #expect(Transcript.text([Cue(start: 0, end: 20, text: "First."), Cue(start: 20, end: 25, text: "Second")]) == "00:00 First.\n00:20 Second")
        #expect(Transcript.stamp(3723) == "1:02:03")
    }

    /// 时间点和简介章节同一个写法：放大查看里能点着跳
    @Test func stampsAreChapters() {
        let text = Transcript.text([Cue(start: 0, end: 30, text: "一"), Cue(start: 95, end: 100, text: "二")])
        #expect(Player.chapters(in: text, duration: 100).map(\.seconds) == [0, 95])
    }

    /// 升级：转录过的卡，正文最后一段分出来成转录；拼回去和原来一样，理解的依据不变
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
