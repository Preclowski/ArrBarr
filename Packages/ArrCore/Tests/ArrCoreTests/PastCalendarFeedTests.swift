import Foundation
import Testing
@testable import ArrCore

@MainActor
@Suite("Past calendar feed")
struct PastCalendarFeedTests {
    private static let day: TimeInterval = 86_400

    private static func item(_ id: String, _ date: Date) -> UpcomingItem {
        UpcomingItem(id: id, source: .sonarr, title: id, subtitle: nil, airDate: date, releaseType: nil, hasFile: false, overview: nil)
    }

    @Test("Walks back over empty fortnights and keeps only rows inside each window")
    func walksBack() async {
        let now = Date()
        let old = Self.item("old", now.addingTimeInterval(-20 * Self.day))
        // A movie dated by its digital release, outside the window that returned it.
        let future = Self.item("future", now.addingTimeInterval(5 * Self.day))
        var windows: [(Date, Date)] = []
        let feed = PastCalendarFeed { start, end in
            windows.append((start, end))
            return [old, future]
        }
        let added = await feed.loadEarlier(now: now)
        #expect(added)
        #expect(feed.items.map(\.id) == ["old"])
        #expect(windows.count == 2)
    }

    @Test("A second load prepends older rows and skips ones already shown")
    func prepends() async {
        let now = Date()
        let recent = Self.item("recent", now.addingTimeInterval(-3 * Self.day))
        let older = Self.item("older", now.addingTimeInterval(-18 * Self.day))
        let feed = PastCalendarFeed { _, _ in [recent, older] }
        await feed.loadEarlier(now: now)
        #expect(feed.items.map(\.id) == ["recent"])
        await feed.loadEarlier(now: now)
        #expect(feed.items.map(\.id) == ["older", "recent"])
    }
}
