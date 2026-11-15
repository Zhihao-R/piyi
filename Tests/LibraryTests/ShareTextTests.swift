import Testing
import Foundation
@testable import Library

/// 复制、分享来的一段文字：指向网页的抓网页，正文里夹着链接的按文字收
struct ShareTextTests {
    private func urls(_ text: String) -> [String] { FileExtractor.urls(in: text).map(\.absoluteString) }

    @Test func appShareTextIsTheLink() {
        #expect(urls("【【熟】提示词美学：勿写提示词】 https://www.bilibili.com/video/BV1Wrp76mEsW/?share_source=copy_web")
                == ["https://www.bilibili.com/video/BV1Wrp76mEsW/?share_source=copy_web"])
        #expect(urls("4.12 复制打开抖音，看看【某人的作品】# 旅行 https://v.douyin.com/iAbCdEf/ 0@5.com 08/11")
                == ["https://v.douyin.com/iAbCdEf/"])
        #expect(urls("看看这个标题https://xhslink.com/a/abc，复制本条信息，打开【小红书】App查看精彩内容！") == ["https://xhslink.com/a/abc"])
    }

    @Test func linksWithoutSchemeCount() {
        #expect(urls("bilibili.com/video/BV1AVwuzpE96/?spm_id_from=333") == ["http://bilibili.com/video/BV1AVwuzpE96/?spm_id_from=333"])
        #expect(urls("https://a.com/1\nb.com/2") == ["https://a.com/1", "http://b.com/2"])
        #expect(urls("README.md").isEmpty)
    }

    /// 文章里夹着链接：整段是内容，链接不去抓
    @Test func linksInsideProseStayText() {
        let prose = String(repeating: "这是一段从文章里复制的正文，讲的是排版。", count: 8)
        #expect(urls(prose + " 参考 https://a.com/x").isEmpty)
        #expect(urls("两篇对照着看：https://a.com/1 和 https://b.com/2 讲的是同一件事").isEmpty)
        #expect(urls("联系 a@b.com 吧").isEmpty)
    }
}
