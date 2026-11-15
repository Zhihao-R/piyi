import Testing
import CoreGraphics
@testable import Canvas

@Suite struct ShelvesTests {
    @Test func groupsStackWithTitleRoomAndNoOverlap() {
        let groups: [[CGFloat]] = [Array(repeating: 1, count: 8), [1], Array(repeating: 0.6, count: 10)]
        let laid = Layout.shelves(groups)
        #expect(laid.map(\.rects.count) == groups.map(\.count))
        for (i, shelf) in laid.enumerated() {
            // 标题区在组里第一行的正上方
            let top = shelf.rects.map(\.minY).min()!
            #expect(top == shelf.title.y + Layout.shelfTitle)
            // 下一组的标题区不压住这一组的卡
            if i + 1 < laid.count { #expect(laid[i + 1].title.y >= shelf.rects.map(\.maxY).max()!) }
        }
        // 所有组同一行宽：两个排了不止一行的组，撑满的那几行右边对齐
        let edges = laid.filter { $0.rects.count > 2 }.map { $0.rects.map(\.maxX).max()! }
        #expect(edges.count == 2 && abs(edges[0] - edges[1]) < 0.01)
    }

    @Test func emptyInputGivesNothing() {
        #expect(Layout.shelves([]).isEmpty)
    }
}
