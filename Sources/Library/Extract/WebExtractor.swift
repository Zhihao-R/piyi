import Foundation
import UniformTypeIdentifiers

/// 网址 → 素材。分层走，每一层交出一次「尝试」，判成失败（素材标了残缺）才进下一层：
/// 1. 直链文件：下载下来按文件处理
/// 2. 平台适配器：YouTube、B 站、X、微博走公开接口；公众号、小红书读页面
/// 3. 通用解析：网站给机器看的标准信息（标题、封面、站名）+ Readability 取正文
/// 4. 用户浏览器打开：交给扩展在你的浏览器里后台打开，拿回渲染好的页面，再走一遍 2、3 层的解析
/// 5. 模型兜底：前几层拿不准时，让模型从页面文字里认出标题和正文
///
/// 2、3 层拆成「下载」和「只解析」两步：第 4 层和扩展收来的页面都只用解析那一步。
/// 帖子类平台按内容长什么样定类型：有视频是视频，有图是图像，只有字是文字。
public struct WebExtractor: Sendable {
    let session: URLSession
    let models: (any ExtractionModels)?
    let browser: (any PageBrowser)?

    public init(session: URLSession = .shared, models: (any ExtractionModels)? = nil, browser: (any PageBrowser)? = nil) {
        self.session = session
        self.models = models
        self.browser = browser
    }

    /// 一层的结果：素材，以及交给模型兜底时要看的页面文字和状态码（读了网页的层才有）
    struct Attempt {
        var material: Material
        var glance: PageGlance?
        var status = 200
    }

    public func material(for url: URL) async -> Material {
        await finished(url) { try await layers(url) }
    }

    /// 扩展收来的：页面已经在你的浏览器里渲染好，直接解析。有公开接口的平台照样先走接口，
    /// 和收网址时一样认得出视频、帖子（B 站的页面上没写自己是视频）；接口不通再解析页面
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
        // 4：没有连上的浏览器时 render 返回 nil，原因留着，扩展连上后补抓
        if Self.browserCanHelp(attempt), let browser {
            do {
                // 小红书的全部内容都在页面自带的数据里，不用滚到底
                if let page = try await browser.render(url, scroll: !Self.isXiaohongshu(url)) {
                    attempt = await parsed(Page(html: page.html, url: page.url))
                    // 浏览器里也是空的：不是缺浏览器，别再等扩展
                    if attempt.material.partial == .needsBrowser { attempt.material.partial = .failed(String(localized: "浏览器里打开也没读到内容")) }
                }
            } catch {
                attempt.material.partial = .failed(String(localized: "浏览器里没读成：\(error.localizedDescription)"))
            }
        }
        // 5
        return await rescued(attempt)
    }

    /// 第 5 层：登录页兜不了；页面上本来就没几个字（靠脚本加载）也兜不了
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

    /// 2、3 层的下载：有公开接口的平台走接口，其余下载网页再解析。服务器说返回的是 PDF、图片、视频时（网址里不一定有后缀），按文件处理
    private func fetched(_ url: URL) async throws -> Attempt {
        if let api = try await platform(url) { return Attempt(material: api) }
        // 小红书的手机版页面更常不要求登录
        let (raw, response) = try await fetch(url, mobile: Self.isXiaohongshu(url), timeout: 30)
        if let mime = response.mimeType, let type = UTType(mimeType: mime),
           type.conforms(to: .pdf) || type.conforms(to: .image) || type.conforms(to: .movie) {
            return Attempt(material: try await downloaded(url, data: raw, ext: type.preferredFilenameExtension ?? "bin"))
        }
        let page = Page(data: raw, url: response.url ?? url) ?? Page(html: "", url: url)
        return await parsed(page, status: (response as? HTTPURLResponse)?.statusCode ?? 200)
    }

    /// 2、3 层的解析：不下载网页，只读手里这一页（App 下载的、浏览器渲染的都行）
    func parsed(_ page: Page, status: Int = 200) async -> Attempt {
        let host = page.url.host()?.lowercased() ?? ""
        if host == "mp.weixin.qq.com" { return Attempt(material: await wechat(page), status: status) }
        if Self.isXiaohongshu(page.url) { return Attempt(material: await xiaohongshu(page), status: status) }
        return await generic(page, status: status)
    }

    /// 浏览器帮得上的失败：要登录、靠脚本加载、拦截页、被网站拦下（401、403、429）。
    /// 断网、网页不存在（404、410）、网站自己出错（5xx），在浏览器里打开也一样；拦截页除外，它常用 503 回
    static func browserCanHelp(_ attempt: Attempt) -> Bool {
        guard let partial = attempt.material.partial, partial != .offline else { return false }
        return partial == .needsBrowser || attempt.status < 400 || [401, 403, 429].contains(attempt.status)
    }

    static func isXiaohongshu(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return host.hasSuffix("xiaohongshu.com") || host == "xhslink.com"
    }

    // MARK: 第 2 层：平台

    /// 有公开接口的平台：YouTube、B 站、X、微博。不是这几个、或者接口里没有这条，返回 nil
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

    /// YouTube：oEmbed 拿标题和作者，缩略图按视频编号取最大尺寸
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

    /// 视频编号：youtu.be/编号，或者 watch?v=编号
    static func youtubeID(_ url: URL) -> String? {
        url.host() == "youtu.be" ? url.lastPathComponent
            : URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
    }

    /// B 站：公开的视频信息接口，有标题、简介、封面、时长、UP 主
    private func bilibili(_ url: URL) async throws -> Material? {
        guard let (target, v) = try await bilibiliVideo(url) else { return nil }
        var m = Material(kind: .video)
        m.title = v["title"] as? String
        m.body = v["desc"] as? String
        m.source = (v["owner"] as? [String: Any])?["name"] as? String
        m.duration = (v["duration"] as? NSNumber)?.doubleValue
        m.format = "B 站"
        m.url = target.absoluteString
        // 编号用接口给的：老的 av 号链接里没有 BV 号
        m.player = (v["bvid"] as? String).map { Player.bilibili(bvid: $0, url: target) }
        if let pic = v["pic"] as? String {
            m.images = await images([pic])
        }
        return m
    }

    /// B 站视频信息接口的 data 和跳转后的网址。b23.tv 短链先跟随跳转
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

    /// X：未登录拿不到页面。图片和视频借公开的 fxtwitter 接口；它不可用时退到官方 oEmbed，至少拿到正文和作者
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
            // 视频流直接播，不下载
            m.player = video?["url"] as? String
            return m
        }
        guard let embed = try await json("https://publish.twitter.com/oembed?omit_script=1&url=\(url.absoluteString)"),
              let html = embed["html"] as? String else { return nil }
        let text = html.firstMatch(#"<p[^>]*>([\s\S]*?)</p>"#, group: 1).map { Page.decode($0.replacing(#/<[^>]+>/#, with: "")) }
        return await post(platform: "X", title: embed["author_name"] as? String, text: text, author: embed["author_name"] as? String,
                              images: [], isVideo: false, duration: nil)
    }

    /// 微博：不认识的访问者先被转到访客验证页，页面跑脚本领一个访客身份再跳回原帖。App 不跑脚本，直接向同一个地址领身份，
    /// 带着它打开手机版详情页，页面自带的数据里有正文、作者、配图。手机分享出来的短链先跟随跳转找出帖子编号
    private func weibo(_ url: URL) async throws -> Material? {
        var id = Self.weiboID(url)
        if id == nil, Self.weiboShortHosts.contains(url.host() ?? ""), let final = try await fetch(url).1.url { id = Self.weiboID(final) }
        guard let id, let cookie = try await weiboVisitor(),
              let status = Self.weiboStatus(in: String(decoding: try await fetch(URL(string: "https://m.weibo.cn/detail/\(id)")!, cookie: cookie).0, as: UTF8.self))
        else { return nil }
        // 转发的：原帖接在后面，自己没配图就用原帖的
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

    /// 手机分享出来的短链：要跟随跳转才知道是哪条
    static let weiboShortHosts: Set = ["mapp.api.weibo.cn", "share.api.weibo.cn"]

    /// 详情页自带的数据里的这条微博
    static func weiboStatus(in html: String) -> [String: Any]? {
        guard let raw = html.firstMatch(#"\$render_data = (\[.*?\])\[0\]"#, group: 1),
              let data = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { return nil }
        return data.first?["status"] as? [String: Any]
    }

    /// 一条微博的正文。长微博在详情页里只有前一段，全文另取；取不到时交回前一段，标上没取全
    private func weiboText(of status: [String: Any], cookie: String) async throws -> (text: String, complete: Bool) {
        let shown = Self.weiboText(status["text"] as? String ?? "")
        guard status["isLongText"] as? Bool == true else { return (shown, true) }
        guard let mid = status["id"] as? String,
              let full = (try await json("https://m.weibo.cn/statuses/extend?id=\(mid)", cookie: cookie)?["data"] as? [String: Any])?["longTextContent"] as? String
        else { return (shown, false) }
        return (Self.weiboText(full), true)
    }

    /// 帖子编号：m.weibo.cn/status/编号、/detail/编号，weibo.com/用户号/编号；访客验证页的 url 参数里是原帖地址
    static func weiboID(_ url: URL) -> String? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let inner = query.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)) { return weiboID(inner) }
        if let id = query.first(where: { $0.name == "weibo_id" })?.value { return id }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == 2, ["status", "detail"].contains(path[0]) || path[0].allSatisfy(\.isNumber),
              path[1].firstMatch(#"^[0-9A-Za-z]{9,}$"#) != nil else { return nil }
        return path[1]
    }

    /// 领一个微博访客身份，交回请求时带的 Cookie
    private func weiboVisitor() async throws -> String? {
        var request = URLRequest(url: URL(string: "https://passport.weibo.com/visitor/genvisitor2")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data("cb=visitor_gray_callback&tid=&from=weibo&webdriver=false".utf8)
        request.setValue(Self.desktopUA, forHTTPHeaderField: "User-Agent")
        let reply = String(decoding: try await send(request).0, as: UTF8.self)
        guard let sub = reply.firstMatch(#""sub":"([^"]+)""#, group: 1), let subp = reply.firstMatch(#""subp":"([^"]+)""#, group: 1) else { return nil }
        return "SUB=\(sub); SUBP=\(subp)"
    }

    /// 微博正文是 HTML：换行留下，话题、链接、表情图的标签去掉，长微博末尾的「全文」链接整个去掉
    static func weiboText(_ html: String) -> String {
        Page.decode(html.replacing(#/<a[^>]*>全文</a>/#, with: "").replacing(#/<br\s*/?>/#, with: "\n").replacing(#/<[^>]+>/#, with: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 帖子（推文、小红书笔记、微博）：有视频是视频，有图是图像，只有字是文字
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
            m.title = isVideo ? title : nil     // 图像卡的标题交给模型
            m.body = text
        }
        return m
    }

    /// 公众号最多存多少张配图；最短边不到这么多像素的（分隔线、小图标）不要
    static let inlineLimit = 30
    static let inlineMinSide: CGFloat = 80

    /// 公众号：正文在 #js_content 里，配图是懒加载的 data-src
    private func wechat(_ page: Page) async -> Material {
        var m = Material(kind: .web)
        m.title = page.meta("og:title") ?? page.html.firstMatch(#"var msg_title = '([^']*)'"#, group: 1)
        m.source = page.html.firstMatch(#"var nickname = htmlDecode\("([^"]*)"\)"#, group: 1) ?? page.meta("author")
        m.format = "公众号"
        m.url = page.url.absoluteString
        // 正文是 #js_content 里面那一段：从它的开标签之后，到紧跟在后面的标签提示框为止（再往后是「修改于」「不喜欢」和二维码）
        var content = page.html.range(of: #"id="js_content"[^>]*>"#, options: .regularExpression).map { String(page.html[$0.upperBound...]) } ?? page.html
        if let end = content.range(of: #"id="js_tags_preview_toast""#) ?? content.range(of: #"id="js_pc_qr_code""#) { content = String(content[..<end.lowerBound]) }
        // 配图留在原位：正文里图的位置写一个占位行，配图按出现顺序存成其余图片。分隔线、小图标这类太扁太小的图不要
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
        // 正文截断后没有位置的图不存
        let gallery = Array(kept.prefix(m.body!.components(separatedBy: Article.imageMark).count - 1))
        m.images = ((cover == nil ? nil : fetched[0]) ?? gallery.first).map { [$0] + gallery } ?? []
        if m.title == nil, m.images.isEmpty { m.partial = .failed(String(localized: "公众号页面没读到内容")) } else if Article.plain(m.body ?? "").count < Self.shortest { m.partial = .needsBrowser }
        return m
    }

    /// 小红书：页面里有一段 __INITIAL_STATE__，含笔记标题、正文和全部配图（轮播图只有当前那张真的加载了，扫 <img> 拿不全）。
    /// 很多笔记要登录才看得到，拿不到时退到 og 标签，标成要登录，交给浏览器
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

    /// 正文里的话题写成「#设计[话题]#」，表情写成「[赞R]」：话题留「#设计」，表情去掉
    static func cleanXiaohongshu(_ desc: String) -> String {
        desc.replacing(#/#([^#\[\n]+)\[话题\]#/#) { "#" + $0.output.1 }
            .replacing(#/\[[^\[\]\n]{1,8}R\]/#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 第 3 层：通用解析

    /// 网站给机器看的标准信息 + Readability 取正文，再判断抓到的是不是失败页
    private func generic(_ page: Page, status: Int) async -> Attempt {
        // 拦截页上什么都没有，标题、地址也不是这条内容的：一样都不留，交给浏览器
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
            // 地址可能写成 //cdn… 或相对路径，和封面一样按页面补全
            let absolute = { (s: String?) in s.flatMap { URL(string: $0, relativeTo: page.url)?.absoluteString } }
            m.player = Player.declared(twitter: absolute(page.meta("twitter:player")),
                                       video: absolute(page.meta("og:video:secure_url") ?? page.meta("og:video:url") ?? page.meta("og:video")),
                                       type: page.meta("og:video:type"))
        }
        if let image, let imageURL = URL(string: image, relativeTo: page.url) {
            // 封面下不来只当没有封面，标题和正文照留
            m.images = await images([imageURL.absoluteString])
        }
        let site = page.url.host() ?? ""
        let glance = PageGlance(url: page.url, title: m.title, text: String((text.isEmpty ? Page.paragraphs(in: page.html) : text).prefix(3000)))
        // 是不是失败页：网站明说出错时直接信它；正文太短按规则算没抓全；否则先问模型，没有能用的服务方再按规则
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

    /// 页面上的字少于这个就算没抓全。B 站视频简介短到 47 字也是正常页，公众号只取出十几个字时是没抓全
    static let shortest = 30

    /// 正文太短：测试里所有模型都把这种页当成正常页（选模型时的测试），所以不问模型。网址、标题里看得出是登录页的提示去登录。
    /// 有图的放过：一张大图配一句说明的作品页（Dribbble、Pinterest）本来就没几个字。公众号不走这里，它的文章本该有正文
    static func clipped(_ glance: PageGlance, hasImage: Bool, site: String) -> Partial? {
        guard glance.text.count < shortest, !hasImage else { return nil }
        let head = ((glance.title ?? "") + " " + glance.text + " " + glance.url.path()).lowercased()
        return loginWords.contains { head.contains($0) } ? .login(site: site) : .needsBrowser
    }

    static let loginWords = ["登录", "登陆", "log in", "login", "sign in", "signin", "扫码"]

    /// 拦截页：网站要先确认来的是浏览器（跑脚本领访客身份、人机验证）才给内容。App 不跑脚本，再抓也还是这一页。
    /// 认地址，或者认标题、且页面上没几个字（文章标题里也可能出现「安全验证」）。遇到新平台的拦截页，往下面两张表里加一行
    static func isChallenge(_ page: Page) -> Bool {
        isChallenge(url: page.url.absoluteString, title: page.title, words: Page.paragraphs(in: page.html).count)
    }

    /// 同一条规则，给手里只有地址、标题、正文字数的时候用（已经收成卡的）
    static func isChallenge(url: String, title: String?, words: Int) -> Bool {
        let url = url.lowercased()
        if challengeURLs.contains(where: url.contains) { return true }
        let title = (title ?? "").lowercased()
        return challengeTitles.contains(where: title.contains) && words < 200
    }

    /// 微博访客验证、知乎和百度的人机验证
    static let challengeURLs = ["passport.weibo.com/visitor/", "passport.weibo.cn/visitor/", "zhihu.com/account/unhuman", "wappass.baidu.com/static/captcha"]
    /// 微博访客验证、Cloudflare 的人机验证、知乎和百度的安全验证
    static let challengeTitles = ["sina visitor system", "just a moment...", "attention required! | cloudflare", "安全验证"]

    /// 规则兜底：抓到的是不是登录页、报错页、要靠脚本加载的空页
    static func judge(status: Int, title: String?, text: String, hasImage: Bool, site: String) -> Partial? {
        let head = ((title ?? "") + " " + text.prefix(300)).lowercased()
        // 正文几乎没有、又有登录字样才算登录页：正常的短页面导航里也常有 Log in
        if status == 401 || (text.count < 200 && !hasImage && Self.loginWords.contains { head.contains($0) }) { return .login(site: site) }
        if status >= 400 { return .failed(String(localized: "网站返回错误（\(status)）")) }
        if text.count <= 200, !hasImage { return .needsBrowser }
        return nil
    }

    /// 从网上下载下来的文件：按文件处理，但出处记网站；临时文件名不能当标题，交给模型起
    private func downloaded(_ url: URL, data: Data? = nil, ext: String? = nil) async throws -> Material {
        let bytes = if let data { data } else { try await fetch(url, timeout: 60).0 }
        let file = FileExtractor.downloads.appending(path: UUID().uuidString + "." + (ext ?? url.pathExtension))
        try bytes.write(to: file)
        var m = await FileExtractor.material(fromFile: file)
        // 图片读进了素材本身，临时文件用不着了；要保留原文件的（PDF、视频）存进文件库后再删
        if m.original == nil { try? FileManager.default.removeItem(at: file) }
        if m.title == file.deletingPathExtension().lastPathComponent { m.title = nil }
        m.source = url.host()
        m.url = url.absoluteString
        return m
    }

    // MARK: 网络

    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// 网页请求都走这里：带浏览器标识，网络偶尔断连时重试两次；断网直接报错。
    /// 带 cookie 时只用它，不用系统存的，免得混进 App 里别处留下的
    func fetch(_ url: URL, mobile: Bool = false, cookie: String? = nil, timeout: TimeInterval = 15) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let cookie {
            request.httpShouldHandleCookies = false
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.setValue(mobile ? Self.mobileUA : Self.desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        // B 站、小红书、微博的图床校验来源
        if let host = url.host(), host.contains("hdslb") { request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer") }
        if let host = url.host(), host.contains("xhscdn") { request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer") }
        if let host = url.host(), host.hasSuffix("sinaimg.cn") { request.setValue("https://weibo.com/", forHTTPHeaderField: "Referer") }
        return try await send(request)
    }

    /// 发请求的唯一出口：调用方自己填好请求（接口要 POST、要别的标识时）也走这里重试
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            // 断网不用再试；超时已经等够了，再试只是让人多等
            do { return try await session.data(for: request) } catch let error as URLError where [.notConnectedToInternet, .timedOut].contains(error.code) {
                throw error
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        throw lastError
    }

    /// 下载一张图；不是图片、太小（图标、表情）都返回 nil。尺寸从文件头读，不解码。
    /// 平台给的图片地址常是 http（B 站、小红书），App 不许走不加密的连接，一律换成 https
    private func image(_ string: String) async throws -> Data? {
        guard var parts = URLComponents(string: string) else { return nil }
        if parts.scheme == "http" { parts.scheme = "https" }
        guard let url = parts.url else { return nil }
        let (data, response) = try await fetch(url, timeout: 20)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let size = FileExtractor.pixelSize(data), max(size.width, size.height) >= 200 else { return nil }
        return data
    }

    /// 并发下载多张图，保持原顺序；单张失败不影响其它
    private func images(_ urls: [String]) async -> [Data] {
        await eachImage(urls).compactMap { $0 }
    }

    /// 同上，但失败的留空位，和网址一一对应
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
