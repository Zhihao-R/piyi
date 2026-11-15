import Testing
import Foundation
import GRDB
@testable import Library

/// 网上的视频在放大查看里播：播放地址怎么来、怎么带开始时间、简介里哪些算章节时间点
struct PlayerTests {
    @Test func embedsYouTubeAndBilibili() {
        #expect(Player.youtube(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10")!) == "https://www.youtube.com/embed/dQw4w9WgXcQ")
        #expect(Player.youtube(URL(string: "https://youtu.be/dQw4w9WgXcQ")!) == "https://www.youtube.com/embed/dQw4w9WgXcQ")
        // 分 P 播那一 P，没写是第一 P
        #expect(Player.bilibili(bvid: "BV1GJ411x7h7", url: URL(string: "https://www.bilibili.com/video/av170001?p=3")!)
                == "https://player.bilibili.com/player.html?bvid=BV1GJ411x7h7&p=3")
        #expect(Player.bilibili(bvid: "BV1GJ411x7h7", url: URL(string: "https://www.bilibili.com/video/BV1GJ411x7h7/")!)
                == "https://player.bilibili.com/player.html?bvid=BV1GJ411x7h7&p=1")
    }

    /// 升级：已经收的 YouTube、B 站视频补上播放地址；跳转过的短链看出处网址；名字里带 youtube.com 的别的网站不算
    @Test func migrationBackfillsPlayers() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "collage-migrate-\(UUID().uuidString).sqlite").path
        let db = try DatabaseQueue(path: path)
        try Schema.migrator.migrate(db, upTo: "v8")
        try db.write { db in
            for (url, source) in [("https://www.youtube.com/watch?v=jNQXAC9IVRw", nil),
                                  ("https://b23.tv/abc", "https://www.bilibili.com/video/BV1GJ411x7h7?p=2"),
                                  ("https://notyoutube.com/watch?v=x", nil),
                                  ("https://vimeo.com/1", nil)] as [(String, String?)] {
                try db.execute(sql: "INSERT INTO card (kind, collectedAt, extraction, tags, url, sourceURL) VALUES ('video', '2026-01-01', 'complete', '[]', ?, ?)",
                               arguments: [url, source])
            }
        }
        try Schema.migrator.migrate(db)
        let players = try db.read { db in try String?.fetchAll(db, sql: "SELECT player FROM card ORDER BY id") }
        #expect(players == ["https://www.youtube.com/embed/jNQXAC9IVRw", "https://player.bilibili.com/player.html?bvid=BV1GJ411x7h7&p=2", nil, nil])
    }

    @Test func readsDeclaredPlayer() {
        #expect(Player.declared(twitter: "https://player.vimeo.com/video/1", video: "https://a.com/v.mp4", type: "video/mp4") == "https://player.vimeo.com/video/1")
        #expect(Player.declared(twitter: nil, video: "https://a.com/embed/1", type: "text/html") == "https://a.com/embed/1")
        #expect(Player.declared(twitter: nil, video: "https://a.com/v.mp4", type: nil) == "https://a.com/v.mp4")
        // Flash、不是 https、没写类型又不像视频文件的都不要
        #expect(Player.declared(twitter: nil, video: "https://a.com/p.swf", type: "application/x-shockwave-flash") == nil)
        #expect(Player.declared(twitter: "http://a.com/player", video: nil, type: nil) == nil)
        #expect(Player.declared(twitter: nil, video: "https://a.com/watch/1", type: nil) == nil)
        // 声明是视频文件、但看不出后缀的：播的时候会被当成网页，不要
        #expect(Player.declared(twitter: nil, video: "https://a.com/get?id=1", type: "video/mp4") == nil)
    }

    @Test func addsStartTime() {
        let bilibili = "https://player.bilibili.com/player.html?bvid=BV1GJ411x7h7&p=1"
        #expect(Player.url(bilibili, start: 34)?.absoluteString == bilibili + "&autoplay=1&danmaku=0&high_quality=1&t=34")
        #expect(Player.url(bilibili, start: 0)?.absoluteString == bilibili + "&autoplay=1&danmaku=0&high_quality=1")
        #expect(Player.url("https://www.youtube.com/embed/abc", start: 76)?.absoluteString == "https://www.youtube.com/embed/abc?autoplay=1&rel=0&start=76")
        // 别的网站的播放器不认得参数，原样打开
        #expect(Player.url("https://player.vimeo.com/video/1", start: 76)?.absoluteString == "https://player.vimeo.com/video/1")
        #expect(Player.canSeek(bilibili) && Player.canSeek("https://video.twimg.com/a/b.mp4?tag=12"))
        #expect(!Player.canSeek("https://player.vimeo.com/video/1"))
    }

    @Test func findsChapters() {
        let text = "简介第一行，会议 10:30 开始\n00:01 勿写提示词\n  01:16 Pointers > Prose\n1:02:03 很后面\n9:99 不是时间\n04:31怎么用"
        let found = Player.chapters(in: text, duration: 300).map { ((text as NSString).substring(with: $0.range), $0.seconds) }
        // 只认行首；超过时长的、秒数不对的、后面直接跟字的不算
        #expect(found.map(\.0) == ["00:01", "01:16"])
        #expect(found.map(\.1) == [1, 76])
        #expect(Player.chapters(in: "1:02:03 很后面", duration: nil).map(\.seconds) == [3723])
    }
}
