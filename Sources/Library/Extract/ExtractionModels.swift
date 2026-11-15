import Foundation

/// 抽取要用的模型能力。资料块不能调智能块，所以只在这里写明需要什么，App 启动时把智能块的实现交进来
public protocol ExtractionModels: Sendable {
    /// 抓回来的是正常内容，还是登录页、报错页、空壳页。nil 表示判断不了（没有能用的服务方），由规则兜底
    func verdict(on page: PageGlance) async -> PageVerdict?
    /// 第 5 层模型兜底：前面几层都拿不准时，让模型从页面文字里认出标题和正文。认不出返回 nil
    func rescue(_ page: PageGlance) async -> (title: String?, body: String)?
    /// 补全正文：视频、音频文件转成一句句带时间的文字。转不了返回 nil
    func transcribe(_ file: URL) async -> [Cue]?
}

/// 交给模型看的页面：网址、标题和页面上的文字
public struct PageGlance: Sendable {
    public var url: URL
    public var title: String?
    public var text: String
}

public enum PageVerdict: String, Sendable {
    case content, login, error, empty
}
