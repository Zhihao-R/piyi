import Testing
import AppKit
@testable import Canvas

@Suite struct MarkdownTests {
    let style = Markdown.Style(body: 10, lineSpacing: 0) { _ in NSColor.black }

    private func blocks(_ s: String) -> [Markdown.Line.Block] { Markdown.parse(s).map(\.block) }

    @Test func recognizesBlocks() {
        #expect(blocks("# 标题\n## 小标题\n- 一\n  - 二\n1. 第一\n> 引用\n正文") ==
                [.heading(1), .heading(2), .bullet(depth: 0), .bullet(depth: 1), .ordered(depth: 0), .quote, .paragraph])
        // 井号后面没有空格不是标题，星号紧贴字不是列表
        #expect(blocks("#话题\n*强调*") == [.paragraph, .paragraph])
    }

    @Test func codeFenceProtectsItsContent() {
        let lines = Markdown.parse("```\n# 不是标题 **不粗**\n```\n**粗**")
        #expect(lines.map(\.block) == [.fence, .code, .fence, .paragraph])
        #expect(!lines[1].spans.contains { $0.bold })
        #expect(lines[3].spans.contains { $0.bold && !$0.marker })
    }

    @Test func renderedDropsMarkersAndKeepsWords() {
        let out = Markdown.rendered("# 标题\n**粗**和*斜*，`代码`，[链接](https://a.com)\n- 列表", style: style).string
        #expect(out == "标题\n粗和斜，代码，链接\n• 列表")
    }

    @Test func renderedKeepsBlankLinesAndDropsFences() {
        #expect(Markdown.rendered("\n一\n\n二", style: style).string == "\n一\n\n二")
        #expect(Markdown.rendered("```\nlet a = 1\n```", style: style).string == "let a = 1")
    }

    @Test func styledKeepsEveryCharacter() {
        let source = "# 标题\n**粗** *斜* `码` [字](u)\n```\nx\n```"
        #expect(Markdown.styled(source, style: style).string == source)
    }

    @Test func asterisksInsideCodeAndLoneStarsStayLiteral() {
        #expect(Markdown.rendered("`a*b*c`", style: style).string == "a*b*c")
        #expect(Markdown.rendered("3 * 4 * 5", style: style).string == "3 * 4 * 5")
        #expect(Markdown.rendered("snake_case_name", style: style).string == "snake_case_name")
    }

    @Test func tripleStarsAreBoldItalic() {
        let line = Markdown.parse("***又粗又斜***")[0]
        #expect(Markdown.rendered("***又粗又斜***", style: style).string == "又粗又斜")
        #expect(line.spans.contains { $0.bold && $0.italic && !$0.marker })
    }

    @Test func dropsTheHeadingThatBecameTheTitle() {
        #expect(Markdown.droppingTitle("计划", from: "# 计划\n\n正文") == "正文")
        #expect(Markdown.droppingTitle("别的", from: "# 计划\n正文") == "# 计划\n正文")
    }
}
