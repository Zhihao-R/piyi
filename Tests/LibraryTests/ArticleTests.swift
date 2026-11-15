import Testing
@testable import Library

/// 正文里的配图标记：切段、对图、去标记
struct ArticleTests {
    let m = Article.imageMark

    @Test func imagesGoBackToTheirParagraphs() {
        let body = ["第一段", m, "第二段", "第三段", m].joined(separator: "\n")
        #expect(Article.segments(body, images: 2) == [.text("第一段"), .image(0), .text("第二段\n第三段"), .image(1)])
    }

    /// 以前抓的公众号没有标记：配图都放到文末
    @Test func unmarkedImagesGoToTheEnd() {
        #expect(Article.segments("正文", images: 2) == [.text("正文"), .image(0), .image(1)])
    }

    /// 标记比图多（图没存下来）：多出的标记不占位置
    @Test func extraMarksAreDropped() {
        let body = [m, "正文", m].joined(separator: "\n")
        #expect(Article.segments(body, images: 1) == [.image(0), .text("正文")])
    }

    /// 结尾的标记后面没有换行，也要去掉
    @Test func plainRemovesEveryMark() {
        #expect(Article.plain(["开头", m, "中间", m].joined(separator: "\n")) == "开头\n中间\n")
    }

    @Test func creditsLookLikeNames() {
        #expect(Article.credit("👨🏻 采访: 壹小姐") == "采访 壹小姐")
        #expect(Article.credit("作者 | 后    雨") == "作者 后    雨")
        #expect(Article.credit("整理编辑：十字路口") == "整理编辑 十字路口")
        // 正文句子不算
        #expect(Article.credit("编辑：这是一个很长的句子，带着标点。") == nil)
        #expect(Article.credit("设计：先做用户研究") == nil)
        #expect(Article.credit("最近，Meta 的 AI 智能体 Muse 引起行业轰动。") == nil)
    }
}
