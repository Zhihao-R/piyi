import Foundation

/// 补全正文里的平台字幕：YouTube、B 站的视频不下载、不转录，有字幕就取字幕
extension WebExtractor {
    /// 一条字幕：语言、是不是平台自动生成的、字幕文件的地址
    struct Track: Equatable {
        var language: String
        var automatic: Bool
        var url: String
    }

    /// 字幕，一句一句带着时间。没有字幕、取不到（B 站没连上浏览器或者没登录、接口变了）时返回 nil
    public func subtitles(for url: URL) async -> [Cue]? {
        let host = url.host()?.lowercased() ?? ""
        let cues: [Cue]? = switch true {
        case host.hasSuffix("youtube.com") || host == "youtu.be": try? await youtubeSubtitles(url)
        case host.hasSuffix("bilibili.com") || host == "b23.tv": try? await bilibiliSubtitles(url)
        default: nil
        }
        guard let cues, !cues.isEmpty else { return nil }
        return cues
    }

    /// 挑一条：原声语言的人工字幕 → 原声的自动字幕 → 中文字幕 → 随便一条。
    /// 要视频里实际说的话：别的语言的人工字幕多半是翻译。原声是哪种语言看自动字幕（平台按声音识别的，排在第一条的是原声）；
    /// 没有自动字幕就认不出原声，按你常用的中文挑
    static func pick(_ tracks: [Track]) -> Track? {
        guard let spoken = tracks.first(where: \.automatic) else {
            return tracks.first { base($0.language) == "zh" } ?? tracks.first
        }
        return tracks.first { !$0.automatic && base($0.language) == base(spoken.language) } ?? spoken
    }

    /// zh-CN、zh-Hans 都算 zh
    private static func base(_ language: String) -> String {
        language.split(separator: "-").first.map(String.init) ?? language
    }

    // MARK: YouTube

    /// 网页版播放器给的字幕地址要带一个只有播放器算得出的令牌（2025 年起，不带就是空的）；VR 客户端的公开播放接口给的地址不用。不用登录
    private func youtubeSubtitles(_ url: URL) async throws -> [Cue]? {
        guard let id = Self.youtubeID(url) else { return nil }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                         forHTTPHeaderField: "User-Agent")
        let client: [String: Any] = ["clientName": "ANDROID_VR", "clientVersion": "1.62.27", "deviceModel": "Quest 3", "androidSdkVersion": 32, "hl": "zh-CN"]
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": ["client": client], "videoId": id])
        let player = try JSONSerialization.jsonObject(with: try await send(request).0) as? [String: Any]
        let captions = (player?["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
        let tracks = (captions?["captionTracks"] as? [[String: Any]] ?? []).compactMap { t -> Track? in
            guard let language = t["languageCode"] as? String, let url = t["baseUrl"] as? String else { return nil }
            return Track(language: language, automatic: t["kind"] as? String == "asr", url: url)
        }
        // 地址里自带 fmt=srv3（XML），换成 JSON
        guard let track = Self.pick(tracks), var address = URLComponents(string: track.url) else { return nil }
        address.queryItems = (address.queryItems ?? []).filter { $0.name != "fmt" } + [URLQueryItem(name: "fmt", value: "json3")]
        guard let events = try await json(address.string ?? "")?["events"] as? [[String: Any]] else { return nil }
        return Self.youtubeCues(events)
    }

    /// json3 格式：每个 event 是一句（毫秒），句子拆成几段（自动字幕一个词一段）
    static func youtubeCues(_ events: [[String: Any]]) -> [Cue] {
        events.compactMap { event in
            let text = (event["segs"] as? [[String: Any]] ?? []).compactMap { $0["utf8"] as? String }.joined()
            guard let start = event["tStartMs"] as? Double, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Cue(start: start / 1000, end: (start + (event["dDurationMs"] as? Double ?? 0)) / 1000, text: text)
        }
    }

    // MARK: B 站

    /// 字幕地址要登录才给（不登录时列表里的地址是空的），借浏览器的登录状态请求；字幕文件本身不用登录。
    /// 分 P 的视频按网址里的 ?p= 取那一 P
    private func bilibiliSubtitles(_ url: URL) async throws -> [Cue]? {
        guard let browser, let (target, video) = try await bilibiliVideo(url), let bvid = video["bvid"] as? String else { return nil }
        let p = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value.flatMap(Int.init) ?? 1
        let pages = video["pages"] as? [[String: Any]] ?? []
        guard let cid = (pages.first { ($0["page"] as? Int) == p }?["cid"] ?? video["cid"]) as? NSNumber,
              let raw = try await browser.request(URL(string: "https://api.bilibili.com/x/player/wbi/v2?bvid=\(bvid)&cid=\(cid)")!),
              let player = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        let list = ((player["data"] as? [String: Any])?["subtitle"] as? [String: Any])?["subtitles"] as? [[String: Any]] ?? []
        // 自动生成的语言写成 ai-zh、ai-en；地址以 // 开头
        let tracks = list.compactMap { t -> Track? in
            guard let lan = t["lan"] as? String, let address = t["subtitle_url"] as? String, !address.isEmpty else { return nil }
            let automatic = lan.hasPrefix("ai-")
            return Track(language: automatic ? String(lan.dropFirst(3)) : lan, automatic: automatic,
                         url: address.hasPrefix("//") ? "https:" + address : address)
        }
        guard let track = Self.pick(tracks), let body = try await json(track.url)?["body"] as? [[String: Any]] else { return nil }
        // 每句的 from、to 是秒
        return body.compactMap { line in
            guard let text = line["content"] as? String, let from = line["from"] as? Double else { return nil }
            return Cue(start: from, end: line["to"] as? Double ?? from, text: text)
        }
    }
}
