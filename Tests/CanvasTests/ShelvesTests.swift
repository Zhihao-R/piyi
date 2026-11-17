import Testing
import CoreGraphics
@testable import Canvas

@Suite struct ShelvesTests {
    @Test func groupsStackWithTitleRoomAndNoOverlap() {
        let groups: [[CGFloat]] = [Array(repeating: 1, count: 8), [1], Array(repeating: 0.6, count: 10)]
        let laid = Layout.shelves(groups)
        #expect(laid.map(\.rects.count) == groups.map(\.count))
        for (i, shelf) in laid.enumerated() {
            // The title area sits right above the group's first row
            let top = shelf.rects.map(\.minY).min()!
            #expect(top == shelf.title.y + Layout.shelfTitle)
            // The next group's title area doesn't cover this group's cards
            if i + 1 < laid.count { #expect(laid[i + 1].title.y >= shelf.rects.map(\.maxY).max()!) }
        }
        // All groups share one row width: for two groups with more than one row, the full rows line up on the right
        let edges = laid.filter { $0.rects.count > 2 }.map { $0.rects.map(\.maxX).max()! }
        #expect(edges.count == 2 && abs(edges[0] - edges[1]) < 0.01)
    }

    @Test func emptyInputGivesNothing() {
        #expect(Layout.shelves([]).isEmpty)
    }
}
