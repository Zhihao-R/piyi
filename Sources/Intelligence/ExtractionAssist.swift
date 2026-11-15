import Foundation
import Library

/// 交给资料块的抽取能力：判断抓回来的是不是失败页，以及第 5 层模型兜底。都经过出口
public struct ExtractionAssist: ExtractionModels {
    let gateway: Gateway

    public init(gateway: Gateway) { self.gateway = gateway }

    /// 问法是选模型时在测试集上试过的，改了要重测
    static let question = Question("这是从一个网址抓回来的网页，判断它属于哪一种。", .choice([
        (PageVerdict.content.rawValue, "正常的内容页：文章、帖子、作品、商品等，有实际内容"),
        (PageVerdict.login.rawValue, "登录页或要求登录才能看的页面"),
        (PageVerdict.error.rawValue, "报错页：404、访问受限、验证码、网站出错"),
        (PageVerdict.empty.rawValue, "空壳页：内容要靠脚本加载，或者只剩 Cookie 弹窗、导航"),
    ]))

    /// 不分流：选型时 Jev 认登录页已经 0.981
    public func verdict(on page: PageGlance) async -> PageVerdict? {
        let facts: Facts = [("网址", page.url.absoluteString), ("标题", page.title ?? "（无）"), ("页面文字（节选）", String(page.text.prefix(1500)))]
        guard let verdict = try? await gateway.judge(facts, [Self.question]).first else { return nil }
        return Self.question.key(of: verdict).flatMap(PageVerdict.init)
    }

    public func rescue(_ page: PageGlance) async -> (title: String?, body: String)? {
        let prompt = """
        下面是一个网页上的全部文字，正文识别算法没能认出正文。请从中找出这篇内容的标题和正文：去掉导航、按钮、版权声明、推荐链接这些页面杂项，正文保留原文，不要改写、不要总结。认不出就让 body 为空字符串。只输出 JSON：{"title":"标题","body":"正文"}

        网址：\(page.url.absoluteString)
        页面文字：
        \(page.text)
        """
        struct Reply: Decodable { var title: String?; var body: String }
        guard let reply = try? await gateway.generate(prompt, as: Reply.self), reply.body.count > 200 else { return nil }
        return (reply.title?.isEmpty == false ? reply.title : nil, reply.body)
    }

    public func transcribe(_ file: URL) async -> [Cue]? {
        try? await gateway.transcribe(file)
    }
}
