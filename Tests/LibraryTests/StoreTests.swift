import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GRDB
@testable import Library

/// 每个测试一个临时资料库
func temporaryStore() throws -> Store {
    try Store(root: FileManager.default.temporaryDirectory.appending(path: "piyi-test-\(UUID().uuidString)"))
}

/// 一张纯色 PNG，颜色不同内容就不同
func png(gray: CGFloat, width: Int = 40, height: Int = 30) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

let someFrame = CGRect(x: 0, y: 0, width: 200, height: 150)

@Suite struct Dedup {
    @Test func sameURLTwiceGivesOneCard() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var page = Material(kind: .web)
        page.url = "https://www.example.com/post/1/?utm_source=x#top"
        let first = try await store.collect(page, into: board, frame: someFrame)
        page.url = "http://example.com/post/1"
        let second = try await store.collect(page, into: board, frame: someFrame)
        guard case .created(let id) = first else { Issue.record("第一次应新建"); return }
        // 同一画板再收一次：还是那张卡，画板里再放一份
        #expect(second == .existing(card: id, restored: false, placed: true))
        #expect(try await store.db.read { try Card.fetchCount($0) } == 1)
        #expect(try await store.items(on: board).count == 2)
    }

    @Test func sameFileTwiceGivesOneCard() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try Data("%PDF-1.4 一份文件".utf8).write(to: file)
        var doc = Material(kind: .document)
        doc.original = file
        _ = try await store.collect(doc, into: board, frame: someFrame)
        let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: file, to: copy)
        doc.original = copy
        let second = try await store.collect(doc, into: board, frame: someFrame)
        guard case .existing = second else { Issue.record("同样内容的文件应查到已有卡"); return }
        #expect(try await store.db.read { try Card.fetchCount($0) } == 1)
    }

    @Test func twoImagesFromSamePageGiveTwoCards() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        for gray in [0.2, 0.8] {
            var image = Material(kind: .image)
            image.images = [png(gray: gray)]
            image.sourceURL = "https://example.com/gallery"
            guard case .created = try await store.collect(image, into: board, frame: someFrame) else {
                Issue.record("不同的图应各自新建"); return
            }
        }
        #expect(try await store.db.read { try Card.fetchCount($0) } == 2)
    }

    @Test func existingCardIsPlacedOnNewBoard() async throws {
        let store = try temporaryStore()
        let a = try await store.createBoard("A").id!, b = try await store.createBoard("B").id!
        var text = Material(kind: .text)
        text.text = "留白不是空"
        guard case .created(let id) = try await store.collect(text, into: a, frame: someFrame) else { return }
        #expect(try await store.collect(text, into: b, frame: someFrame) == .existing(card: id, restored: false, placed: true))
        #expect(try await store.boards(containing: id).count == 2)
    }

    @Test func collectingTrashedCardRestoresIt() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var text = Material(kind: .text)
        text.text = "吾生也有涯"
        guard case .created(let id) = try await store.collect(text, into: board, frame: someFrame) else { return }
        try await store.trash([id])
        #expect(try await store.collect(text, into: board, frame: someFrame) == .existing(card: id, restored: true, placed: false))
        #expect(try await store.card(id)?.trashedAt == nil)
    }

    @Test func coverGetsSmallestThumbnailImmediately() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var image = Material(kind: .image)
        image.images = [png(gray: 0.5, width: 600, height: 400)]
        guard case .created(let id) = try await store.collect(image, into: board, frame: someFrame),
              let cover = try await store.card(id)?.cover else { Issue.record("应有封面"); return }
        #expect(FileManager.default.fileExists(atPath: store.files.thumbnailURL(of: cover, tier: 256).path))
    }
}

@Suite struct URLKeys {
    @Test(arguments: [
        ("https://www.Example.com/a/?utm_source=x&utm_medium=y#section", "https://example.com/a"),
        ("http://example.com/a?b=2&a=1", "https://example.com/a?a=1&b=2"),
        ("https://www.bilibili.com/video/BV1W4411Y76B/?spm_id_from=333&vd_source=abc", "https://bilibili.com/video/BV1W4411Y76B"),
        ("https://www.xiaohongshu.com/explore/123?xsec_token=abc&xsec_source=pc", "https://xiaohongshu.com/explore/123"),
        ("https://example.com/", "https://example.com"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(URLKey.of(input) == expected)
    }

    @Test func rejectsNonWeb() {
        #expect(URLKey.of("file:///tmp/a.pdf") == nil)
        #expect(URLKey.of("不是网址") == nil)
    }
}

@Suite struct Boards {
    @Test func movingACardWritesOneRow() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        for i in 0..<5 {
            var text = Material(kind: .text)
            text.text = "第 \(i) 张"
            _ = try await store.collect(text, into: board, frame: someFrame)
        }
        var target = try await store.items(on: board)[2].placement
        target.frame = CGRect(x: 400, y: 300, width: 200, height: 150)
        let before = try await store.db.write { $0.totalChangesCount }
        try await store.update([target])
        let after = try await store.db.write { $0.totalChangesCount }
        #expect(after - before == 1)
        #expect(try await store.items(on: board).first { $0.id == target.id }?.placement.frame.minX == 400)
    }

    @Test func removedPlacementsComeBackWithTheirIDs() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var text = Material(kind: .text)
        text.text = "一张"
        _ = try await store.collect(text, into: board, frame: someFrame)
        let before = try await store.items(on: board).map(\.placement)
        let removed = try await store.removePlacements(before.compactMap(\.id))
        #expect(removed == before)
        #expect(try await store.items(on: board).isEmpty)
        // 拿走后又放进一张：新摆放不占用拿走的编号
        try await store.place(card: removed[0].cardID!, on: board, frame: someFrame)
        try await store.exchangePlacements(adding: removed, removing: [])
        #expect(try await store.items(on: board).map(\.placement).contains(before[0]))
    }

    @Test func placementsOfDeletedBoardsAreSkipped() async throws {
        let store = try temporaryStore()
        let a = try await store.createBoard("A").id!, b = try await store.createBoard("B").id!
        let entry = try await store.placeEntry(b, on: a, frame: someFrame)
        try await store.removePlacements([entry.id!])
        try await store.deleteBoard(b, trashingOrphans: false)
        try await store.exchangePlacements(adding: [entry], removing: [])
        #expect(try await store.items(on: a).isEmpty)
    }

    @Test func puttingBackAnEntryNeverMakesACycle() async throws {
        let store = try temporaryStore()
        let a = try await store.createBoard("A").id!, b = try await store.createBoard("B").id!
        let entry = try await store.placeEntry(b, on: a, frame: someFrame)
        try await store.removePlacements([entry.id!])
        try await store.placeEntry(a, on: b, frame: someFrame)
        try await store.exchangePlacements(adding: [entry], removing: [])
        #expect(try await store.items(on: a).isEmpty)
    }

    @Test func updatingARemovedPlacementIsSkipped() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var text = Material(kind: .text)
        text.text = "一张"
        _ = try await store.collect(text, into: board, frame: someFrame)
        let p = try await store.items(on: board)[0].placement
        try await store.removePlacements([p.id!])
        try await store.update([p])
        #expect(try await store.items(on: board).isEmpty)
    }

    @Test func updateWritesCrop() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var text = Material(kind: .text)
        text.text = "一张"
        _ = try await store.collect(text, into: board, frame: someFrame)
        var p = try await store.items(on: board)[0].placement
        p.crop = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        try await store.update([p])
        #expect(try await store.items(on: board)[0].placement.crop == p.crop)
    }

    @Test func nestingCycleIsRejected() async throws {
        let store = try temporaryStore()
        let a = try await store.createBoard("A").id!, b = try await store.createBoard("B").id!, c = try await store.createBoard("C").id!
        try await store.placeEntry(b, on: a, frame: someFrame)
        try await store.placeEntry(c, on: b, frame: someFrame)
        await #expect(throws: Store.Failure.cycle) { try await store.placeEntry(a, on: c, frame: someFrame) }
        await #expect(throws: Store.Failure.cycle) { try await store.placeEntry(a, on: a, frame: someFrame) }
        // 同一个画板放进两个画板不算环
        try await store.placeEntry(c, on: a, frame: someFrame)
    }

    @Test func trashAndRestoreKeepsPlacements() async throws {
        let store = try temporaryStore()
        let a = try await store.createBoard("A").id!, b = try await store.createBoard("B").id!
        var text = Material(kind: .text)
        text.text = "知人者智"
        guard case .created(let id) = try await store.collect(text, into: a, frame: someFrame) else { return }
        try await store.place(card: id, on: b, frame: CGRect(x: 60, y: 80, width: 100, height: 100))
        try await store.trash([id])
        #expect(try await store.items(on: a).isEmpty)
        #expect(try await store.items(on: b).isEmpty)
        try await store.restore([id])
        #expect(try await store.items(on: a).map(\.placement.frame) == [someFrame])
        #expect(try await store.items(on: b).map(\.placement.frame) == [CGRect(x: 60, y: 80, width: 100, height: 100)])
    }

    /// 粘贴前挑出还没进废纸篓的
    @Test func liveSkipsTrashedCards() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var a = Material(kind: .text), b = Material(kind: .text)
        a.text = "上善若水"
        b.text = "大音希声"
        guard case .created(let kept) = try await store.collect(a, into: board, frame: someFrame),
              case .created(let gone) = try await store.collect(b, into: board, frame: someFrame) else { return }
        try await store.trash([gone])
        #expect(try await store.live([kept, gone]) == [kept])
    }

    @Test func sharedFileSurvivesDeletingOneCard() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        let cover = png(gray: 0.3)
        // 两张网页卡用了同一张封面图
        var ids: [Int64] = []
        for n in 1...2 {
            var page = Material(kind: .web)
            page.url = "https://example.com/\(n)"
            page.images = [cover]
            guard case .created(let id) = try await store.collect(page, into: board, frame: someFrame) else { return }
            ids.append(id)
        }
        let name = try #require(try await store.card(ids[0])?.cover)
        #expect(try await store.card(ids[1])?.cover == name)
        try await store.trash([ids[0]])
        try await store.emptyTrash()
        #expect(try await store.card(ids[0]) == nil)
        #expect(FileManager.default.fileExists(atPath: store.files.url(of: name).path))
        try await store.trash([ids[1]])
        try await store.emptyTrash()
        #expect(!FileManager.default.fileExists(atPath: store.files.url(of: name).path))
    }

    @Test func purgeDeletesOnlyChosenTrashedCards() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var ids: [Int64] = []
        for n in 1...3 {
            var note = Material(kind: .text)
            note.text = "第 \(n) 张"
            guard case .created(let id) = try await store.collect(note, into: board, frame: someFrame) else { return }
            ids.append(id)
        }
        try await store.trash([ids[0], ids[1]])
        // 第三张不在废纸篓里，点名也不删
        try await store.purge([ids[0], ids[2]])
        #expect(try await store.card(ids[0]) == nil)
        #expect(try await store.card(ids[1]) != nil)
        #expect(try await store.card(ids[2]) != nil)
    }

    @Test func deletingBoardHandlesOrphansAndEntries() async throws {
        let store = try temporaryStore()
        let a = try await store.createBoard("A").id!, b = try await store.createBoard("B").id!
        var only = Material(kind: .text), shared = Material(kind: .text)
        only.text = "只在 B"
        shared.text = "A 和 B 都有"
        guard case .created(let onlyID) = try await store.collect(only, into: b, frame: someFrame),
              case .created(let sharedID) = try await store.collect(shared, into: b, frame: someFrame) else { return }
        try await store.place(card: sharedID, on: a, frame: someFrame)
        try await store.placeEntry(b, on: a, frame: someFrame)
        #expect(try await store.cardsOnlyOn(b) == [onlyID])
        try await store.deleteBoard(b, trashingOrphans: true)
        #expect(try await store.card(onlyID)?.trashedAt != nil)
        #expect(try await store.card(sharedID)?.trashedAt == nil)
        // A 里只剩那张共有的卡，指向 B 的入口没了
        #expect(try await store.items(on: a).count == 1)
    }
}
