import Foundation

/// Platform subtitles for body completion: YouTube and Bilibili videos aren't downloaded or transcribed; take subtitles if there are any
extension WebExtractor {
    /// One subtitle track: language, whether the platform auto-generated it, the subtitle file's address
    struct Track: Equatable {
        var language: String
        var automatic: Bool
        var url: String
    }

    /// Subtitles, line by line with times. Returns nil if there are none or they can't be fetched (Bilibili with no browser connected or not logged in, the API changed)
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

    /// Pick one: human subtitles in the spoken language → auto subtitles in the spoken language → subtitles in the interface language → any.
    /// We want what's actually said in the video: human subtitles in other languages are mostly translations. The spoken language comes from the auto subtitles (the platform recognizes it from the audio; the first one listed is the original);
    /// without auto subtitles the spoken language can't be told, so pick by interface language
    static func pick(_ tracks: [Track]) -> Track? {
        guard let spoken = tracks.first(where: \.automatic) else {
            return tracks.first { base($0.language) == interfaceLanguage } ?? tracks.first
        }
        return tracks.first { !$0.automatic && base($0.language) == base(spoken.language) } ?? spoken
    }

    /// zh-CN and zh-Hans both count as zh
    private static func base(_ language: String) -> String {
        language.split(separator: "-").first.map(String.init) ?? language
    }

    // MARK: YouTube

    /// Subtitle addresses from the web player need a token only the player can compute (since 2025; without it they're empty); those from the VR client's public player API don't. No login needed
    private func youtubeSubtitles(_ url: URL) async throws -> [Cue]? {
        guard let id = Self.youtubeID(url) else { return nil }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                         forHTTPHeaderField: "User-Agent")
        let client: [String: Any] = ["clientName": "ANDROID_VR", "clientVersion": "1.62.27", "deviceModel": "Quest 3", "androidSdkVersion": 32, "hl": interfaceLanguage]
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": ["client": client], "videoId": id])
        let player = try JSONSerialization.jsonObject(with: try await send(request).0) as? [String: Any]
        let captions = (player?["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
        let tracks = (captions?["captionTracks"] as? [[String: Any]] ?? []).compactMap { t -> Track? in
            guard let language = t["languageCode"] as? String, let url = t["baseUrl"] as? String else { return nil }
            return Track(language: language, automatic: t["kind"] as? String == "asr", url: url)
        }
        // The address comes with fmt=srv3 (XML); switch it to JSON
        guard let track = Self.pick(tracks), var address = URLComponents(string: track.url) else { return nil }
        address.queryItems = (address.queryItems ?? []).filter { $0.name != "fmt" } + [URLQueryItem(name: "fmt", value: "json3")]
        guard let events = try await json(address.string ?? "")?["events"] as? [[String: Any]] else { return nil }
        return Self.youtubeCues(events)
    }

    /// json3 format: each event is one line (milliseconds), split into several segments (one word per segment for auto subtitles)
    static func youtubeCues(_ events: [[String: Any]]) -> [Cue] {
        events.compactMap { event in
            let text = (event["segs"] as? [[String: Any]] ?? []).compactMap { $0["utf8"] as? String }.joined()
            guard let start = event["tStartMs"] as? Double, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Cue(start: start / 1000, end: (start + (event["dDurationMs"] as? Double ?? 0)) / 1000, text: text)
        }
    }

    // MARK: Bilibili

    /// Subtitle addresses require login (without it the addresses in the list are empty), so request with the browser's login state; the subtitle files themselves don't need login.
    /// Multi-part videos take the part given by ?p= in the URL
    private func bilibiliSubtitles(_ url: URL) async throws -> [Cue]? {
        guard let browser, let (target, video) = try await bilibiliVideo(url), let bvid = video["bvid"] as? String else { return nil }
        let p = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value.flatMap(Int.init) ?? 1
        let pages = video["pages"] as? [[String: Any]] ?? []
        guard let cid = (pages.first { ($0["page"] as? Int) == p }?["cid"] ?? video["cid"]) as? NSNumber,
              let raw = try await browser.request(URL(string: "https://api.bilibili.com/x/player/wbi/v2?bvid=\(bvid)&cid=\(cid)")!),
              let player = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        let list = ((player["data"] as? [String: Any])?["subtitle"] as? [String: Any])?["subtitles"] as? [[String: Any]] ?? []
        // Auto-generated languages are written ai-zh, ai-en; addresses start with //
        let tracks = list.compactMap { t -> Track? in
            guard let lan = t["lan"] as? String, let address = t["subtitle_url"] as? String, !address.isEmpty else { return nil }
            let automatic = lan.hasPrefix("ai-")
            return Track(language: automatic ? String(lan.dropFirst(3)) : lan, automatic: automatic,
                         url: address.hasPrefix("//") ? "https:" + address : address)
        }
        guard let track = Self.pick(tracks), let body = try await json(track.url)?["body"] as? [[String: Any]] else { return nil }
        // from and to of each line are in seconds
        return body.compactMap { line in
            guard let text = line["content"] as? String, let from = line["from"] as? Double else { return nil }
            return Cue(start: from, end: line["to"] as? Double ?? from, text: text)
        }
    }
}
