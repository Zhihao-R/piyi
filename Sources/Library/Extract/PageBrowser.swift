import Foundation

/// 借你的浏览器做的事（借用浏览器里的登录状态）：第 4 层打开网页，让页面自己的脚本跑完；取要登录才给的平台字幕。
/// 资料块不认识浏览器扩展，只在这里写明需要什么，App 启动时把实现交进来
public protocol PageBrowser: Sendable {
    /// 在后台打开网址，等页面渲染完（scroll 为真时还要滚到底，让懒加载的内容出来），交回整页 HTML。
    /// 没有连上的浏览器时返回 nil；打开了但没读成时抛错
    func render(_ url: URL, scroll: Bool) async throws -> RenderedPage?
    /// 带着登录状态请求网址（不开标签页），交回响应原文。没有连上的浏览器时返回 nil；请求失败时抛错
    func request(_ url: URL) async throws -> String?
}

/// 浏览器渲染好的一页：最终网址（跳转之后的）和整页 HTML
public struct RenderedPage: Sendable {
    public var url: URL
    public var html: String

    public init(url: URL, html: String) {
        self.url = url
        self.html = html
    }
}
