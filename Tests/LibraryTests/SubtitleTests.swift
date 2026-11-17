import Testing
import Foundation
@testable import Library

/// Platform subtitles: which track to pick, fetching Bilibili with the browser's sign-in state, saving as a transcript once fetched.
/// Uses recorded network responses, in the same serialized group as the web page samples
extension WebFixtureTests { @Suite @MainActor struct SubtitleTests {
    typealias Track = WebExtractor.Track

    @Test func picksSpokenLanguage() {
        let auto = Track(language: "en", automatic: true, url: "asr")
        let german = Track(language: "de-DE", automatic: false, url: "de")
        let english = Track(language: "en-US", automatic: false, url: "en")
        let chinese = Track(language: "zh-Hans", automatic: false, url: "zh")
        // Human subtitles in other languages are mostly translations: take the original language; human ones are more accurate than automatic
        #expect(WebExtractor.pick([german, chinese, auto, english]) == english)
        #expect(WebExtractor.pick([german, chinese, auto]) == auto)
        // When the original language can't be told, pick Chinese
        #expect(WebExtractor.pick([german, chinese]) == chinese)
        // Bilibili: AI subtitles in the original language come first, translations after; when there are human Chinese subtitles, use those
        let ai = [Track(language: "zh", automatic: true, url: "ai-zh"), Track(language: "en", automatic: true, url: "ai-en")]
        #expect(WebExtractor.pick(ai)?.url == "ai-zh")
        #expect(WebExtractor.pick(ai + [Track(language: "zh-CN", automatic: false, url: "zh-CN")])?.url == "zh-CN")
        #expect(WebExtractor.pick([]) == nil)
    }

    @Test func readsYouTubeEvents() {
        let events: [[String: Any]] = [["tStartMs": 1500.0, "dDurationMs": 2000.0, "segs": [["utf8": "We're no"], ["utf8": " strangers"]]],
                                       ["tStartMs": 3000.0, "segs": [["utf8": "\n"]]], ["tStartMs": 3500.0], ["tStartMs": 4000.0, "dDurationMs": 1000.0, "segs": [["utf8": "to love"]]]]
        #expect(WebExtractor.youtubeCues(events) == [Cue(start: 1.5, end: 3.5, text: "We're no strangers"), Cue(start: 4, end: 5, text: "to love")])
    }

    static let video = "https://www.bilibili.com/video/BV15Zpb6iEd6/?p=2"
    static let player = "https://api.bilibili.com/x/player/wbi/v2?bvid=BV15Zpb6iEd6&cid=222"
    static let subtitle = "https://aisubtitle.hdslb.com/bfs/ai_subtitle/prod/abc?auth_key=1"

    func serve() {
        let view = #"{"code":0,"data":{"bvid":"BV15Zpb6iEd6","cid":111,"title":"科教频道","desc":"简介","pages":[{"page":1,"cid":111},{"page":2,"cid":222}]}}"#
        let file = #"{"body":[{"from":0.5,"to":3,"content":"你的童年有没有科教频道"},{"from":3,"to":5.2,"content":"提到童年回忆"}]}"#
        Replay.responses = [
            "https://api.bilibili.com/x/web-interface/view?bvid=BV15Zpb6iEd6": .init(status: 200, contentType: "application/json", finalURL: "", body: Data(view.utf8)),
            Self.subtitle: .init(status: 200, contentType: "application/json", finalURL: Self.subtitle, body: Data(file.utf8)),
        ]
    }

    /// The subtitle list has URLs only after sign-in
    static let signedIn = #"{"code":0,"data":{"subtitle":{"subtitles":[{"lan":"ai-zh","subtitle_url":"//aisubtitle.hdslb.com/bfs/ai_subtitle/prod/abc?auth_key=1"}]}}}"#
    static let signedOut = #"{"code":0,"data":{"subtitle":{"subtitles":[{"lan":"ai-zh","subtitle_url":""}]}}}"#

    @Test func bilibiliSubtitlesNeedBrowserLogin() async {
        serve()
        let url = URL(string: Self.video)!
        let browser = FakeBrowser(html: "", answers: [Self.player: Self.signedIn])
        #expect(await WebExtractor(session: Replay.session, browser: browser).subtitles(for: url) == [Cue(start: 0.5, end: 3, text: "你的童年有没有科教频道"), Cue(start: 3, end: 5.2, text: "提到童年回忆")])
        #expect(await WebExtractor(session: Replay.session, browser: FakeBrowser(html: "", answers: [Self.player: Self.signedOut])).subtitles(for: url) == nil)
        // No browser connected
        #expect(await WebExtractor(session: Replay.session, browser: FakeBrowser(html: nil)).subtitles(for: url) == nil)
        #expect(await WebExtractor(session: Replay.session).subtitles(for: url) == nil)
    }

    @Test func subtitlesCompleteBodyOnce() async throws {
        serve()
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var m = Material(kind: .video)
        m.body = "简介"
        m.url = Self.video
        guard case .created(let id) = try await store.collect(m, into: board, frame: .zero) else { throw CancellationError() }

        // No browser connected: only the description, so the summary must be marked "Based on the description only"
        try await Extractor(session: Replay.session, browser: FakeBrowser(html: nil)).completeBody(of: id, in: store)
        #expect(try await store.card(id)?.transcript == nil)

        let extractor = Extractor(session: Replay.session, browser: FakeBrowser(html: "", answers: [Self.player: Self.signedIn]))
        try await extractor.completeBody(of: id, in: store)
        try await extractor.completeBody(of: id, in: store)
        let card = try #require(try await store.card(id))
        #expect(card.body == "简介")
        #expect(card.transcript == "00:00 你的童年有没有科教频道 提到童年回忆")
    }
} }
