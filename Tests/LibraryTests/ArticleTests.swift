import Testing
@testable import Library

/// Image markers in body text: splitting into segments, matching images, removing markers
struct ArticleTests {
    let m = Article.imageMark

    @Test func imagesGoBackToTheirParagraphs() {
        let body = ["第一段", m, "第二段", "第三段", m].joined(separator: "\n")
        #expect(Article.segments(body, images: 2) == [.text("第一段"), .image(0), .text("第二段\n第三段"), .image(1)])
    }

    /// WeChat articles fetched earlier have no markers: all images go at the end
    @Test func unmarkedImagesGoToTheEnd() {
        #expect(Article.segments("正文", images: 2) == [.text("正文"), .image(0), .image(1)])
    }

    /// More markers than images (images weren't saved): extra markers take no space
    @Test func extraMarksAreDropped() {
        let body = [m, "正文", m].joined(separator: "\n")
        #expect(Article.segments(body, images: 1) == [.image(0), .text("正文")])
    }

    /// A marker at the end with no line break after it is removed too
    @Test func plainRemovesEveryMark() {
        #expect(Article.plain(["开头", m, "中间", m].joined(separator: "\n")) == "开头\n中间\n")
    }

    @Test func creditsLookLikeNames() {
        #expect(Article.credit("👨🏻 采访: 壹小姐") == "采访 壹小姐")
        #expect(Article.credit("作者 | 后    雨") == "作者 后    雨")
        #expect(Article.credit("整理编辑：十字路口") == "整理编辑 十字路口")
        // Body sentences don't count
        #expect(Article.credit("编辑：这是一个很长的句子，带着标点。") == nil)
        #expect(Article.credit("设计：先做用户研究") == nil)
        #expect(Article.credit("最近，Meta 的 AI 智能体 Muse 引起行业轰动。") == nil)
    }
}
