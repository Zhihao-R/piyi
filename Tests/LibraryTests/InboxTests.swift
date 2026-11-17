import Testing
import Foundation
@testable import Library

/// Files in the phone inbox → things to collect: .txt saved by Shortcuts are collected as text, other files the same as dragged-in ones
@Suite struct InboxTests {
    private func shared(_ name: String, _ data: Data) -> [Source]? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: name)
        try? data.write(to: file)
        return FileExtractor.sources(fromShared: file)
    }

    @Test func textWithOnlyLinksBecomesLinks() {
        let urls = shared("文本.txt", Data("https://a.com/1\nhttps://b.com/2\n".utf8))?.compactMap(\.url).map(\.absoluteString)
        #expect(urls == ["https://a.com/1", "https://b.com/2"])
    }

    @Test func plainTextBecomesText() {
        guard case .text(let text)? = shared("文本.txt", Data("一句想法".utf8))?.first else { Issue.record("应当是文字"); return }
        #expect(text == "一句想法")
    }

    @Test func emptyTextBecomesNothing() {
        #expect(shared("文本.txt", Data("  \n".utf8))?.isEmpty == true)
    }

    @Test func nonUTF8TextIsStillText() throws {
        let gbk = try #require("片羽收件箱里的一段中文".data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))))
        guard case .text(let text)? = shared("文本.txt", gbk)?.first else { Issue.record("应当是文字"); return }
        #expect(text == "片羽收件箱里的一段中文")
    }

    @Test func otherFilesAreCollectedLikeDraggedFiles() {
        for name in ["照片.png", "报告.pdf", "笔记.md"] {
            guard case .file(let file)? = shared(name, Data("x".utf8))?.first else { Issue.record("\(name) 应当按文件收"); continue }
            #expect(file.lastPathComponent == name)
        }
    }

    @Test func unreadableTextIsLeftForLater() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        #expect(FileExtractor.sources(fromShared: missing) == nil)
    }
}
