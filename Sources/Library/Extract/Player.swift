import Foundation

/// Online videos aren't downloaded; the detail view plays them with the platform's own player.
/// Two kinds of player address: the player page a platform offers for embedding on other sites, or the video stream itself (X's videos)
public enum Player {
    /// YouTube's embed player. Returns nil if the video ID can't be recognized
    static func youtube(_ url: URL) -> String? {
        WebExtractor.youtubeID(url).map { "https://www.youtube.com/embed/\($0)" }
    }

    /// Bilibili's embed player. Multi-part videos play the part given by ?p= in the URL
    static func bilibili(bvid: String, url: URL) -> String {
        let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value.flatMap(Int.init) ?? 1
        return "https://player.bilibili.com/player.html?bvid=\(bvid)&p=\(p)"
    }

    /// A player another site declares in its page: twitter:player is a player page for embedding on other sites;
    /// og:video is a player page (type text/html) or a video file. Video files only when the extension is recognizable: playback branches on the extension, so both places must use the same standard.
    /// https only, no Flash and the like
    static func declared(twitter: String?, video: String?, type: String?) -> String? {
        if let twitter, twitter.hasPrefix("https://") { return twitter }
        guard let video, video.hasPrefix("https://") else { return nil }
        return type?.lowercased() == "text/html" || isStream(video) ? video : nil
    }

    /// The video stream itself (played directly by the system player), not a player page
    public static func isStream(_ player: String) -> Bool {
        guard let ext = URL(string: player)?.pathExtension.lowercased() else { return false }
        return ["mp4", "m4v", "mov", "m3u8"].contains(ext)
    }

    /// Can start playing from a given time: the two platforms' embed players and video streams. Other sites' players don't recognize the parameter
    public static func canSeek(_ player: String) -> Bool {
        isStream(player) || isYouTube(player) || isBilibili(player)
    }

    /// The address used when opening: it only loads once play is clicked, so autoplay directly; Bilibili with danmaku off and high quality. start is in seconds; video streams seek in the player, not via the address
    public static func url(_ player: String, start: Int) -> URL? {
        guard var parts = URLComponents(string: player) else { return nil }
        var extra: [URLQueryItem] = []
        if isBilibili(player) {
            extra = [.init(name: "autoplay", value: "1"), .init(name: "danmaku", value: "0"), .init(name: "high_quality", value: "1")]
            if start > 0 { extra.append(.init(name: "t", value: "\(start)")) }
        } else if isYouTube(player) {
            extra = [.init(name: "autoplay", value: "1"), .init(name: "rel", value: "0")]
            if start > 0 { extra.append(.init(name: "start", value: "\(start)")) }
        }
        if !extra.isEmpty { parts.queryItems = (parts.queryItems ?? []) + extra }
        return parts.url
    }

    /// Timestamps at the start of lines in a description (chapters like "00:34 Scope beats prompts"): their position in the text and seconds.
    /// Only at line starts, so clock times mentioned in the body aren't taken as timestamps; ones past the video's duration don't count
    public static func chapters(in text: String, duration: Double?) -> [(range: NSRange, seconds: Int)] {
        guard let regex = try? NSRegularExpression(pattern: #"^[ \t]*((?:(\d{1,2}):)?(\d{1,2}):(\d{2}))(?=\s|$)"#, options: .anchorsMatchLines) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            func number(_ group: Int) -> Int? {
                match.range(at: group).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: group)))
            }
            guard let minutes = number(3), let seconds = number(4), seconds < 60 else { return nil }
            let hours = number(2)
            if hours != nil, minutes >= 60 { return nil }
            let total = (hours ?? 0) * 3600 + minutes * 60 + seconds
            if let duration, Double(total) > duration { return nil }
            return (match.range(at: 1), total)
        }
    }

    private static func isYouTube(_ player: String) -> Bool { player.hasPrefix("https://www.youtube.com/embed/") }
    private static func isBilibili(_ player: String) -> Bool { player.hasPrefix("https://player.bilibili.com/") }
}
