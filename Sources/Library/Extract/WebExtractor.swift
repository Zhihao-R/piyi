import Foundation
import UniformTypeIdentifiers

/// URL → material. Goes in layers; each layer hands back one "attempt", and only when it's judged a failure (material marked partial) does it move on to the next:
/// 1. Direct file links: download and handle as a file
/// 2. Platform adapters: YouTube, Bilibili, X, Weibo go through public APIs; WeChat Official Accounts and Xiaohongshu read the page
/// 3. Generic parsing: the standard info sites provide for machines (title, cover, site name) + Readability for the body
/// 4. Open in the user's browser: hand it to the extension to open in your browser in the background, get the rendered page back, and run layers 2 and 3 parsing again
/// 5. Model fallback: when the earlier layers are unsure, have the model pick out the title and body from the page text
///
/// Layers 2 and 3 are split into "download" and "parse only": layer 4 and pages collected by the extension only use the parse step.
/// Post-style platforms set the kind by what the content looks like: with video it's video, with images it's image, text only is text.
public struct WebExtractor: Sendable {
    let session: URLSession
    let models: (any ExtractionModels)?
    let browser: (any PageBrowser)?

    public init(session: URLSession = .shared, models: (any ExtractionModels)? = nil, browser: (any PageBrowser)? = nil) {
        self.session = session
        self.models = models
        self.browser = browser
    }

    /// One layer's result: the material, plus the page text and status code for the model fallback to look at (only layers that read a web page have them)
    struct Attempt {
        var material: Material
        var glance: PageGlance?
        var status = 200
    }

    public func material(for url: URL) async -> Material {
        await finished(url) { try await layers(url) }
    }

    /// Collected by the extension: the page is already rendered in your browser, so parse it directly. Platforms with public APIs still go through the API first,
    /// so videos and posts are recognized the same as when collecting a URL (Bilibili's page doesn't say it's a video); parse the page only if the API fails
    public func material(rendered page: RenderedPage) async -> Material {
        await finished(page.url) {
            if let api = try? await platform(page.url) { return api }
            var attempt = await parsed(Page(html: page.html, url: page.url))
            if attempt.material.partial == .needsBrowser { attempt.material.partial = .failed(String(localized: "页面上没读到内容")) }
            return await rescued(attempt)
        }
    }

    private func finished(_ url: URL, _ work: () async throws -> Material) async -> Material {
        var m: Material
        do {
            m = try await work()
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            m = Material(kind: .web)
            m.partial = .offline
        } catch {
            m = Material(kind: .web)
            m.partial = .failed(String(localized: "没抓到：\(error.localizedDescription)"))
        }
        m.url = m.url ?? url.absoluteString
        if m.title == nil, m.kind != .image, m.kind != .text { m.title = url.host() }
        return m
    }

    static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]

    private func layers(_ url: URL) async throws -> Material {
        // 1
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()),
           type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie) {
            return try await downloaded(url)
        }
        // 2、3
        var attempt = try await fetched(url)
        // 4: render returns nil when no browser is connected; the reason is kept, and it's refetched once the extension connects
        if Self.browserCanHelp(attempt), let browser {
            do {
                // All of Xiaohongshu's content is in the page's built-in data, no need to scroll to the bottom
                if let page = try await browser.render(url, scroll: !Self.isXiaohongshu(url)) {
                    attempt = await parsed(Page(html: page.html, url: page.url))
                    // Empty in the browser too: it's not that the browser was missing, so stop waiting for the extension
                    if attempt.material.partial == .needsBrowser { attempt.material.partial = .failed(String(localized: "浏览器里打开也没读到内容")) }
                }
            } catch {
                attempt.material.partial = .failed(String(localized: "浏览器里没读成：\(error.localizedDescription)"))
            }
        }
        // 5
        return await rescued(attempt)
    }

    /// Layer 5: login pages can't be rescued; nor can pages with hardly any text to begin with (loaded via scripts)
    private func rescued(_ attempt: Attempt) async -> Material {
        var m = attempt.material
        let rescuable = switch m.partial { case .needsBrowser?, .failed?: attempt.status < 400; default: false }
        if rescuable, let glance = attempt.glance, glance.text.count > 200, let rescued = await models?.rescue(glance) {
            m.title = rescued.title ?? m.title
            m.body = String(rescued.body.prefix(FileExtractor.bodyLimit))
            m.partial = nil
        }
        return m
    }

    /// Layers 2 and 3 download: platforms with public APIs go through the API, the rest download the page and parse it. When the server says it's returning a PDF, image or video (the URL may lack an extension), handle it as a file
    private func fetched(_ url: URL) async throws -> Attempt {
        if let api = try await platform(url) { return Attempt(material: api) }
        // Xiaohongshu's mobile pages more often don't require login
        let (raw, response) = try await fetch(url, mobile: Self.isXiaohongshu(url), timeout: 30)
        if let mime = response.mimeType, let type = UTType(mimeType: mime),
           type.conforms(to: .pdf) || type.conforms(to: .image) || type.conforms(to: .movie) {
            return Attempt(material: try await downloaded(url, data: raw, ext: type.preferredFilenameExtension ?? "bin"))
        }
        let page = Page(data: raw, url: response.url ?? url) ?? Page(html: "", url: url)
        return await parsed(page, status: (response as? HTTPURLResponse)?.statusCode ?? 200)
    }

    /// Layers 2 and 3 parse: no download, only read the page at hand (downloaded by the app or rendered by the browser)
    func parsed(_ page: Page, status: Int = 200) async -> Attempt {
        let host = page.url.host()?.lowercased() ?? ""
        if host == "mp.weixin.qq.com" { return Attempt(material: await wechat(page), status: status) }
        if Self.isXiaohongshu(page.url) { return Attempt(material: await xiaohongshu(page), status: status) }
        return await generic(page, status: status)
    }

    /// Failures the browser can help with: login required, loaded via scripts, block pages, blocked by the site (401, 403, 429).
    /// Offline, page not found (404, 410), the site's own errors (5xx) are the same in the browser; except block pages, which often answer with 503
    static func browserCanHelp(_ attempt: Attempt) -> Bool {
        guard let partial = attempt.material.partial, partial != .offline else { return false }
        return partial == .needsBrowser || attempt.status < 400 || [401, 403, 429].contains(attempt.status)
    }

    static func isXiaohongshu(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return host.hasSuffix("xiaohongshu.com") || host == "xhslink.com"
    }

    // MARK: Layer 2: platforms

    /// Platforms with public APIs: YouTube, Bilibili, X, Weibo. Returns nil if it's none of these, or the API doesn't have this item
    private func platform(_ url: URL) async throws -> Material? {
        let host = url.host()?.lowercased() ?? ""
        return switch true {
        case host.hasSuffix("youtube.com") || host == "youtu.be": try await youtube(url)
        case host.hasSuffix("bilibili.com") || host == "b23.tv": try await bilibili(url)
        case host == "x.com" || host.hasSuffix("twitter.com"): try await xPost(url)
        case host.hasSuffix("weibo.com") || host.hasSuffix("weibo.cn"): try await weibo(url)
        default: nil
        }
    }

    /// YouTube: oEmbed for the title and author, the thumbnail at the largest size by video ID
    private func youtube(_ url: URL) async throws -> Material? {
        guard let id = Self.youtubeID(url),
              let info = try await json("https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v=\(id)") else { return nil }
        var m = Material(kind: .video)
        m.title = info["title"] as? String
        m.source = info["author_name"] as? String
        m.format = "YouTube"
        m.player = Player.youtube(url)
        m.images = await images(["https://i.ytimg.com/vi/\(id)/maxresdefault.jpg"])
        if m.images.isEmpty { m.images = await images(["https://i.ytimg.com/vi/\(id)/mqdefault.jpg"]) }
        return m
    }

    /// Video ID: youtu.be/<id>, or watch?v=<id>
    static func youtubeID(_ url: URL) -> String? {
        url.host() == "youtu.be" ? url.lastPathComponent
            : URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
    }

    /// Bilibili: the public video info API, with title, description, cover, duration, uploader
    private func bilibili(_ url: URL) async throws -> Material? {
        guard let (target, v) = try await bilibiliVideo(url) else { return nil }
        var m = Material(kind: .video)
        m.title = v["title"] as? String
        m.body = v["desc"] as? String
        m.source = (v["owner"] as? [String: Any])?["name"] as? String
        m.duration = (v["duration"] as? NSNumber)?.doubleValue
        m.format = "B 站"
        m.url = target.absoluteString
        // Use the ID from the API: old av-number links have no BV ID
        m.player = (v["bvid"] as? String).map { Player.bilibili(bvid: $0, url: target) }
        if let pic = v["pic"] as? String {
            m.images = await images([pic])
        }
        return m
    }

    /// The data from Bilibili's video info API and the redirected URL. b23.tv short links are followed first
    func bilibiliVideo(_ url: URL) async throws -> (URL, [String: Any])? {
        var target = url
        if url.host() == "b23.tv" { target = try await fetch(url).1.url ?? url }
        let s = target.absoluteString
        let query: String
        if let bv = s.firstMatch(#"BV[0-9A-Za-z]{10}"#) { query = "bvid=\(bv)" }
        else if let av = s.firstMatch(#"av(\d+)"#, group: 1) { query = "aid=\(av)" }
        else { return nil }
        guard let response = try await json("https://api.bilibili.com/x/web-interface/view?\(query)"),
              let v = response["data"] as? [String: Any] else { return nil }
        return (target, v)
    }

    /// X: pages can't be fetched without login. Images and videos come from the public fxtwitter API; when it's unavailable, fall back to the official oEmbed, getting at least the text and author
    private func xPost(_ url: URL) async throws -> Material? {
        guard let id = url.absoluteString.firstMatch(#"status/(\d+)"#, group: 1) else { return nil }
        if let tweet = try await json("https://api.fxtwitter.com/status/\(id)")?["tweet"] as? [String: Any] {
            let media = tweet["media"] as? [String: Any]
            let author = tweet["author"] as? [String: Any]
            let photos = (media?["photos"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
            let video = (media?["videos"] as? [[String: Any]])?.first
            var m = await post(platform: "X", title: author?["name"] as? String, text: tweet["text"] as? String,
                               author: (author?["screen_name"] as? String).map { "@" + $0 },
                               images: video.flatMap { $0["thumbnail_url"] as? String }.map { [$0] } ?? photos,
                               isVideo: video != nil, duration: (video?["duration"] as? NSNumber)?.doubleValue)
            // Play the video stream directly, no download
            m.player = video?["url"] as? String
            return m
        }
        guard let embed = try await json("https://publish.twitter.com/oembed?omit_script=1&url=\(url.absoluteString)"),
              let html = embed["html"] as? String else { return nil }
        let text = html.firstMatch(#"<p[^>]*>([\s\S]*?)</p>"#, group: 1).map { Page.decode($0.replacing(#/<[^>]+>/#, with: "")) }
        return await post(platform: "X", title: embed["author_name"] as? String, text: text, author: embed["author_name"] as? String,
                              images: [], isVideo: false, duration: nil)
    }

    /// Weibo: unknown visitors are first sent to a visitor check page, where a script gets a visitor identity and jumps back to the post. The app doesn't run scripts, so it gets the identity from the same address directly,
    /// and opens the mobile detail page with it; the page's built-in data has the text, author and images. Short links shared from the phone are followed first to find the post ID
    private func weibo(_ url: URL) async throws -> Material? {
        var id = Self.weiboID(url)
        if id == nil, Self.weiboShortHosts.contains(url.host() ?? ""), let final = try await fetch(url).1.url { id = Self.weiboID(final) }
        guard let id, let cookie = try await weiboVisitor(),
              let status = Self.weiboStatus(in: String(decoding: try await fetch(URL(string: "https://m.weibo.cn/detail/\(id)")!, cookie: cookie).0, as: UTF8.self))
        else { return nil }
        // Reposts: the original post follows; if the repost has no images of its own, use the original's
        let original = status["retweeted_status"] as? [String: Any]
        let own = try await weiboText(of: status, cookie: cookie)
        var quoted: (text: String, complete: Bool)?
        if let original { quoted = try await weiboText(of: original, cookie: cookie) }
        let name = (original?["user"] as? [String: Any])?["screen_name"] as? String
        let text = [own.text, quoted.map { (name.map { "@\($0)：" } ?? "") + $0.text }].compactMap { $0 }.joined(separator: "\n\n")

        let pictures = { (s: [String: Any]?) in (s?["pics"] as? [[String: Any]] ?? []).compactMap { ($0["large"] as? [String: Any])?["url"] as? String } }
        let video = [status, original].compactMap { $0?["page_info"] as? [String: Any] }.first { $0["type"] as? String == "video" }
        let cover = (video?["page_pic"] as? [String: Any])?["url"] as? String
        let images = cover.map { [$0] } ?? (pictures(status).isEmpty ? pictures(original) : pictures(status))
        var m = await post(platform: "微博", title: video?["title"] as? String ?? status["status_title"] as? String, text: text,
                           author: (status["user"] as? [String: Any])?["screen_name"] as? String, images: images,
                           isVideo: video != nil, duration: ((video?["media_info"] as? [String: Any])?["duration"] as? NSNumber)?.doubleValue)
        m.url = "https://m.weibo.cn/detail/\(id)"
        if !own.complete || quoted?.complete == false { m.partial = .failed(String(localized: "长微博只取到前一段")) }
        return m
    }

    /// Short links shared from the phone: only following the redirect tells which post it is
    static let weiboShortHosts: Set = ["mapp.api.weibo.cn", "share.api.weibo.cn"]

    /// This Weibo post in the detail page's built-in data
    static func weiboStatus(in html: String) -> [String: Any]? {
        guard let raw = html.firstMatch(#"\$render_data = (\[.*?\])\[0\]"#, group: 1),
              let data = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { return nil }
        return data.first?["status"] as? [String: Any]
    }

    /// A Weibo post's text. Long posts only have the first part in the detail page, the full text is fetched separately; if that fails, return the first part marked incomplete
    private func weiboText(of status: [String: Any], cookie: String) async throws -> (text: String, complete: Bool) {
        let shown = Self.weiboText(status["text"] as? String ?? "")
        guard status["isLongText"] as? Bool == true else { return (shown, true) }
        guard let mid = status["id"] as? String,
              let full = (try await json("https://m.weibo.cn/statuses/extend?id=\(mid)", cookie: cookie)?["data"] as? [String: Any])?["longTextContent"] as? String
        else { return (shown, false) }
        return (Self.weiboText(full), true)
    }

    /// Post ID: m.weibo.cn/status/<id>, /detail/<id>, weibo.com/<user id>/<id>; the url parameter of the visitor check page holds the original post address
    static func weiboID(_ url: URL) -> String? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let inner = query.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)) { return weiboID(inner) }
        if let id = query.first(where: { $0.name == "weibo_id" })?.value { return id }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == 2, ["status", "detail"].contains(path[0]) || path[0].allSatisfy(\.isNumber),
              path[1].firstMatch(#"^[0-9A-Za-z]{9,}$"#) != nil else { return nil }
        return path[1]
    }

    /// Get a Weibo visitor identity, returning the Cookie to send with requests
    private func weiboVisitor() async throws -> String? {
        var request = URLRequest(url: URL(string: "https://passport.weibo.com/visitor/genvisitor2")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data("cb=visitor_gray_callback&tid=&from=weibo&webdriver=false".utf8)
        request.setValue(Self.desktopUA, forHTTPHeaderField: "User-Agent")
        let reply = String(decoding: try await send(request).0, as: UTF8.self)
        guard let sub = reply.firstMatch(#""sub":"([^"]+)""#, group: 1), let subp = reply.firstMatch(#""subp":"([^"]+)""#, group: 1) else { return nil }
        return "SUB=\(sub); SUBP=\(subp)"
    }

    /// Weibo text is HTML: keep line breaks, strip tags of topics, links and emoji images, and drop the 「全文」 ("full text") link at the end of long posts entirely
    static func weiboText(_ html: String) -> String {
        Page.decode(html.replacing(#/<a[^>]*>全文</a>/#, with: "").replacing(#/<br\s*/?>/#, with: "\n").replacing(#/<[^>]+>/#, with: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Posts (tweets, Xiaohongshu notes, Weibo posts): with video it's video, with images it's image, text only is text
    private func post(platform: String, title: String?, text: String?, author: String?,
                      images urls: [String], isVideo: Bool, duration: Double?) async -> Material {
        let images = await images(urls)
        var m = Material(kind: isVideo ? .video : (images.isEmpty ? .text : .image))
        m.format = platform
        m.source = author
        m.duration = duration
        m.images = images
        if m.kind == .text {
            m.text = text
        } else {
            m.title = isVideo ? title : nil     // image cards' titles are left to the model
            m.body = text
        }
        return m
    }

    /// How many images a WeChat Official Accounts article keeps at most; ones whose shortest side is under this many pixels (dividers, small icons) are dropped
    static let inlineLimit = 30
    static let inlineMinSide: CGFloat = 80

    /// WeChat Official Accounts: the body is in #js_content, images are lazy-loaded data-src
    private func wechat(_ page: Page) async -> Material {
        var m = Material(kind: .web)
        m.title = page.meta("og:title") ?? page.html.firstMatch(#"var msg_title = '([^']*)'"#, group: 1)
        m.source = page.html.firstMatch(#"var nickname = htmlDecode\("([^"]*)"\)"#, group: 1) ?? page.meta("author")
        m.format = "公众号"
        m.url = page.url.absoluteString
        // The body is the part inside #js_content: from after its opening tag up to the tag preview popup right after it (beyond that are "edited on", "dislike" and the QR code)
        var content = page.html.range(of: #"id="js_content"[^>]*>"#, options: .regularExpression).map { String(page.html[$0.upperBound...]) } ?? page.html
        if let end = content.range(of: #"id="js_tags_preview_toast""#) ?? content.range(of: #"id="js_pc_qr_code""#) { content = String(content[..<end.lowerBound]) }
        // Images stay in place: write a placeholder line in the body where each image goes, and store the images in order of appearance as the other images. Images too flat or small, like dividers and small icons, are dropped
        let blocks = Page.blocks(in: content, image: #"data-src="(https?://mmbiz\.qpic\.cn[^"]+)""#)
        var inline: [String] = []
        for case .image(let u) in blocks where !inline.contains(u) && inline.count < Self.inlineLimit { inline.append(u) }
        let cover = page.meta("og:image")
        let fetched = await eachImage([cover].compactMap { $0 } + inline)
        var pictures: [String: Data] = [:]
        for (u, d) in zip(inline, fetched.suffix(inline.count)) {
            if let d, let size = FileExtractor.pixelSize(d), min(size.width, size.height) >= Self.inlineMinSide { pictures[u] = d }
        }
        var kept: [Data] = []
        let lines = blocks.compactMap { block -> String? in
            switch block {
            case .text(let t): return t
            case .image(let u):
                guard let d = pictures[u] else { return nil }
                kept.append(d)
                return Article.imageMark
            }
        }
        m.body = String(lines.joined(separator: "\n").prefix(FileExtractor.bodyLimit))
        // Images left without a position after the body is truncated aren't stored
        let gallery = Array(kept.prefix(m.body!.components(separatedBy: Article.imageMark).count - 1))
        m.images = ((cover == nil ? nil : fetched[0]) ?? gallery.first).map { [$0] + gallery } ?? []
        if m.title == nil, m.images.isEmpty { m.partial = .failed(String(localized: "公众号页面没读到内容")) } else if Article.plain(m.body ?? "").count < Self.shortest { m.partial = .needsBrowser }
        return m
    }

    /// Xiaohongshu: the page has an __INITIAL_STATE__ block with the note's title, body and all images (in a carousel only the current one is actually loaded, so scanning <img> misses some).
    /// Many notes need login to view; when it can't be had, fall back to the og tags, mark as needing login, and hand it to the browser
    private func xiaohongshu(_ page: Page) async -> Material {
        if let note = Self.xiaohongshuNote(in: page.html) {
            let urls = (note["imageList"] as? [[String: Any]] ?? []).compactMap { ($0["urlDefault"] ?? $0["url"]) as? String }
            let title = (note["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var m = await post(platform: "小红书", title: title,
                               text: [title, (note["desc"] as? String).map(Self.cleanXiaohongshu)].compactMap { $0 }.joined(separator: "\n"),
                               author: (note["user"] as? [String: Any])?["nickname"] as? String,
                               images: urls, isVideo: (note["type"] as? String) == "video", duration: nil)
            m.url = page.url.absoluteString
            return m
        }
        var m = await post(platform: "小红书", title: page.meta("og:title"), text: page.meta("description") ?? page.meta("og:title"),
                           author: nil, images: [page.meta("og:image")].compactMap { $0 }, isVideo: false, duration: nil)
        m.partial = .login(site: "小红书")
        return m
    }

    static func xiaohongshuNote(in html: String) -> [String: Any]? {
        guard let raw = html.firstMatch(#"window\.__INITIAL_STATE__\s*=\s*(\{.*?\})\s*</script>"#, group: 1)?
                .replacingOccurrences(of: "undefined", with: "null"),
              let state = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let map = (state["note"] as? [String: Any])?["noteDetailMap"] as? [String: Any] else { return nil }
        return map.values.compactMap { ($0 as? [String: Any])?["note"] as? [String: Any] }
            .first { !(($0["title"] as? String) ?? "").isEmpty || !(($0["desc"] as? String) ?? "").isEmpty }
    }

    /// Topics in the body are written as 「#设计[话题]#」 and emoji as 「[赞R]」: keep topics as 「#设计」 ("#design"), drop the emoji
    static func cleanXiaohongshu(_ desc: String) -> String {
        desc.replacing(#/#([^#\[\n]+)\[话题\]#/#) { "#" + $0.output.1 }
            .replacing(#/\[[^\[\]\n]{1,8}R\]/#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Layer 3: generic parsing

    /// The standard info sites provide for machines + Readability for the body, then judge whether what was fetched is a failure page
    private func generic(_ page: Page, status: Int) async -> Attempt {
        // A block page has nothing on it, and its title and address aren't this content's either: keep none of it, hand it to the browser
        if Self.isChallenge(page) {
            var m = Material(kind: .web)
            m.partial = .needsBrowser
            return Attempt(material: m, status: status)
        }
        let article = await Readability.parse(page.html, url: page.url)
        let image = page.meta("og:image") ?? page.meta("twitter:image")
        let text = article?.text ?? ""
        let description = page.meta("og:description") ?? page.meta("description")
        let isVideo = page.meta("og:type")?.hasPrefix("video") == true

        var m = Material(kind: isVideo ? .video : .web)
        m.title = page.meta("og:title") ?? article?.title ?? page.title
        m.body = text.count > 200 ? String(text.prefix(FileExtractor.bodyLimit)) : description
        m.source = page.meta("og:site_name") ?? article?.siteName ?? article?.byline ?? page.url.host()
        m.format = isVideo ? (page.meta("og:site_name") ?? "视频") : nil
        m.url = page.url.absoluteString
        if isVideo {
            // The address may be written as //cdn… or a relative path; complete it against the page, like the cover
            let absolute = { (s: String?) in s.flatMap { URL(string: $0, relativeTo: page.url)?.absoluteString } }
            m.player = Player.declared(twitter: absolute(page.meta("twitter:player")),
                                       video: absolute(page.meta("og:video:secure_url") ?? page.meta("og:video:url") ?? page.meta("og:video")),
                                       type: page.meta("og:video:type"))
        }
        if let image, let imageURL = URL(string: image, relativeTo: page.url) {
            // If the cover can't be downloaded, treat it as having no cover; keep the title and body
            m.images = await images([imageURL.absoluteString])
        }
        let site = page.url.host() ?? ""
        let glance = PageGlance(url: page.url, title: m.title, text: String((text.isEmpty ? Page.paragraphs(in: page.html) : text).prefix(3000)))
        // Is it a failure page: trust the site when it plainly reports an error; a body that's too short counts as not fully fetched by rule; otherwise ask the model first, falling back to rules if there's no usable provider
        if status >= 400 {
            m.partial = Self.judge(status: status, title: m.title, text: text, hasImage: !m.images.isEmpty, site: site)
        } else if let clipped = Self.clipped(glance, hasImage: !m.images.isEmpty, site: site) {
            m.partial = clipped
        } else {
            m.partial = await models?.verdict(on: glance).map { Self.partial(for: $0, site: site) }
                ?? Self.judge(status: status, title: m.title, text: text, hasImage: !m.images.isEmpty, site: site)
        }
        return Attempt(material: m, glance: glance, status: status)
    }

    static func partial(for verdict: PageVerdict, site: String) -> Partial? {
        switch verdict {
        case .content: nil
        case .login: .login(site: site)
        case .error: .failed(String(localized: "网站返回的是报错页"))
        case .empty: .needsBrowser
        }
    }

    /// Fewer characters than this on the page counts as not fully fetched. A Bilibili video description as short as 47 characters is a normal page; a WeChat Official Accounts article yielding only a dozen or so characters is not fully fetched
    static let shortest = 30

    /// Body too short: in tests every model took such pages as normal (tests when choosing models), so the model isn't asked. If the URL or title shows it's a login page, prompt to log in.
    /// Pages with images pass: a work page with one big image and a line of caption (Dribbble, Pinterest) has few words to begin with. WeChat Official Accounts don't come through here, as their articles should have a body
    static func clipped(_ glance: PageGlance, hasImage: Bool, site: String) -> Partial? {
        guard glance.text.count < shortest, !hasImage else { return nil }
        let head = ((glance.title ?? "") + " " + glance.text + " " + glance.url.path()).lowercased()
        return loginWords.contains { head.contains($0) } ? .login(site: site) : .needsBrowser
    }

    static let loginWords = ["登录", "登陆", "log in", "login", "sign in", "signin", "扫码"]

    /// Block page: the site wants to confirm the visitor is a browser (running a script to get a visitor identity, a captcha) before giving content. The app doesn't run scripts, so refetching still gets this page.
    /// Match by address, or by title with hardly any text on the page (an article title can also contain 「安全验证」, "security check"). For a new platform's block page, add a row to one of the two tables below
    static func isChallenge(_ page: Page) -> Bool {
        isChallenge(url: page.url.absoluteString, title: page.title, words: Page.paragraphs(in: page.html).count)
    }

    /// The same rule, for when only the address, title and body length are at hand (cards already collected)
    static func isChallenge(url: String, title: String?, words: Int) -> Bool {
        let url = url.lowercased()
        if challengeURLs.contains(where: url.contains) { return true }
        let title = (title ?? "").lowercased()
        return challengeTitles.contains(where: title.contains) && words < 200
    }

    /// Weibo's visitor check, Zhihu's and Baidu's captchas
    static let challengeURLs = ["passport.weibo.com/visitor/", "passport.weibo.cn/visitor/", "zhihu.com/account/unhuman", "wappass.baidu.com/static/captcha"]
    /// Weibo's visitor check, Cloudflare's captcha, Zhihu's and Baidu's security check
    static let challengeTitles = ["sina visitor system", "just a moment...", "attention required! | cloudflare", "安全验证"]

    /// Rule fallback: whether what was fetched is a login page, an error page, or an empty page that needs scripts to load
    static func judge(status: Int, title: String?, text: String, hasImage: Bool, site: String) -> Partial? {
        let head = ((title ?? "") + " " + text.prefix(300)).lowercased()
        // Only a login page if there's almost no body and login wording: normal short pages often have Log in in their navigation too
        if status == 401 || (text.count < 200 && !hasImage && Self.loginWords.contains { head.contains($0) }) { return .login(site: site) }
        if status >= 400 { return .failed(String(localized: "网站返回错误（\(status)）")) }
        if text.count <= 200, !hasImage { return .needsBrowser }
        return nil
    }

    /// A file downloaded from the web: handled as a file, but the source records the site; the temporary file name can't be the title, so the model names it
    private func downloaded(_ url: URL, data: Data? = nil, ext: String? = nil) async throws -> Material {
        let bytes = if let data { data } else { try await fetch(url, timeout: 60).0 }
        let file = FileExtractor.downloads.appending(path: UUID().uuidString + "." + (ext ?? url.pathExtension))
        try bytes.write(to: file)
        var m = await FileExtractor.material(fromFile: file)
        // Images are read into the material itself, so the temporary file isn't needed; ones that keep the original (PDF, video) are deleted after being saved to the file store
        if m.original == nil { try? FileManager.default.removeItem(at: file) }
        if m.title == file.deletingPathExtension().lastPathComponent { m.title = nil }
        m.source = url.host()
        m.url = url.absoluteString
        return m
    }

    // MARK: Network

    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// All web requests go through here: with a browser user agent, retrying twice on occasional disconnects; offline fails right away.
    /// With a cookie, use only it and not the system's stored ones, so nothing left elsewhere in the app gets mixed in
    func fetch(_ url: URL, mobile: Bool = false, cookie: String? = nil, timeout: TimeInterval = 15) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let cookie {
            request.httpShouldHandleCookies = false
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.setValue(mobile ? Self.mobileUA : Self.desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        // Image hosts of Bilibili, Xiaohongshu and Weibo check the referer
        if let host = url.host(), host.contains("hdslb") { request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer") }
        if let host = url.host(), host.contains("xhscdn") { request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer") }
        if let host = url.host(), host.hasSuffix("sinaimg.cn") { request.setValue("https://weibo.com/", forHTTPHeaderField: "Referer") }
        return try await send(request)
    }

    /// The single exit for sending requests: callers that build their own request (an API needing POST or another user agent) also retry through here
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            // No point retrying offline; a timeout has already waited long enough, retrying only makes people wait longer
            do { return try await session.data(for: request) } catch let error as URLError where [.notConnectedToInternet, .timedOut].contains(error.code) {
                throw error
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        throw lastError
    }

    /// Download one image; returns nil if it's not an image or too small (icons, emoji). Size is read from the file header, without decoding.
    /// Platforms often give http image addresses (Bilibili, Xiaohongshu), and the app doesn't allow unencrypted connections, so switch them all to https
    private func image(_ string: String) async throws -> Data? {
        guard var parts = URLComponents(string: string) else { return nil }
        if parts.scheme == "http" { parts.scheme = "https" }
        guard let url = parts.url else { return nil }
        let (data, response) = try await fetch(url, timeout: 20)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let size = FileExtractor.pixelSize(data), max(size.width, size.height) >= 200 else { return nil }
        return data
    }

    /// Download several images concurrently, keeping the original order; one failing doesn't affect the others
    private func images(_ urls: [String]) async -> [Data] {
        await eachImage(urls).compactMap { $0 }
    }

    /// Same as above, but failures leave an empty slot, matching the URLs one to one
    private func eachImage(_ urls: [String]) async -> [Data?] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (i, u) in urls.enumerated() { group.addTask { (i, try? await self.image(u)) } }
            var out = [Data?](repeating: nil, count: urls.count)
            for await (i, d) in group { out[i] = d }
            return out
        }
    }

    func json(_ string: String, cookie: String? = nil) async throws -> [String: Any]? {
        guard let url = URL(string: string) else { return nil }
        return (try? JSONSerialization.jsonObject(with: try await fetch(url, cookie: cookie).0)) as? [String: Any]
    }
}
