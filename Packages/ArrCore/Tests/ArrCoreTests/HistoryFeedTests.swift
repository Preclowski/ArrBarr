import Foundation
import Testing
@testable import ArrCore

@Suite("History feed paging")
@MainActor
struct HistoryFeedTests {
    @MainActor
    final class RequestLog {
        var pages: [Int] = []
    }

    /// One album's per-track imports — the whole page folds into one row.
    static func albumPage(_ page: Int, tracks: Int = 4, album: Int? = nil) -> [HistoryItem] {
        let album = album ?? page
        let hint = HistoryItem.GroupHint(key: "album-\(album)")
        return (0..<tracks).map { track in
            HistoryItem(
                id: "p\(page)-a\(album)-t\(track)", source: .lidarr,
                date: Date(timeIntervalSince1970: 1_000_000 - Double(page * 100 + track)),
                eventType: .imported, title: "Artist", subtitle: "Album \(album)", sourceTitle: nil,
                quality: "FLAC", customFormats: [], customFormatScore: 0, groupHint: hint
            )
        }
    }

    /// `rows` unrelated grabs — one row each.
    static func plainPage(_ page: Int, rows: Int) -> [HistoryItem] {
        (0..<rows).map { row in
            HistoryItem(
                id: "p\(page)-r\(row)", source: .radarr,
                date: Date(timeIntervalSince1970: 1_000_000 - Double(page * 100 + row)),
                eventType: .grabbed, title: "Movie \(page)-\(row)", subtitle: nil, sourceTitle: nil,
                quality: nil, customFormats: [], customFormatScore: 0
            )
        }
    }

    @Test("A batch keeps paging until it has its rows, however much the records fold")
    func batchCountsRowsNotRecords() async {
        let log = RequestLog()
        let feed = HistoryFeed(sources: [.lidarr], rowsPerBatch: 3, maxPagesPerBatch: 10) { _, page in
            log.pages.append(page)
            return HistoryResult(items: Self.albumPage(page), hasMore: true, error: nil)
        }
        await feed.load()
        #expect(feed.items.count == 3)
        #expect(log.pages == [1, 2, 3])
    }

    @Test("A batch stops at the page cap even if the rows never come")
    func pageCap() async {
        let log = RequestLog()
        let feed = HistoryFeed(sources: [.lidarr], rowsPerBatch: 50, maxPagesPerBatch: 2) { _, page in
            log.pages.append(page)
            return HistoryResult(items: Self.albumPage(page), hasMore: true, error: nil)
        }
        await feed.load()
        #expect(log.pages == [1, 2])
        #expect(feed.items.count == 2)
        #expect(feed.hasMore)
    }

    @Test("loadMore appends the next batch and stops when the arr runs out")
    func loadMoreUntilExhausted() async {
        let feed = HistoryFeed(sources: [.radarr], rowsPerBatch: 2) { _, page in
            HistoryResult(items: Self.plainPage(page, rows: 2), hasMore: page < 2, error: nil)
        }
        await feed.load()
        #expect(feed.items.count == 2)
        #expect(feed.hasMore)
        await feed.loadMore()
        #expect(feed.items.count == 4)
        #expect(!feed.hasMore)
        await feed.loadMore()
        #expect(feed.items.count == 4)
    }

    @Test("An album split across two pages folds into one row once both are loaded")
    func batchAcrossPagesFolds() async {
        let feed = HistoryFeed(sources: [.lidarr], rowsPerBatch: 1) { _, page in
            let items = page == 1
                ? Array(Self.albumPage(1, album: 7).prefix(2))
                : Array(Self.albumPage(2, album: 7).suffix(2)) + Self.albumPage(3, album: 8)
            return HistoryResult(items: items, hasMore: page < 2, error: nil)
        }
        await feed.load()
        #expect(feed.items.map(\.groupedCount) == [2])
        await feed.loadMore()
        #expect(feed.items.map(\.groupedCount) == [4, 4])
    }

    @MainActor
    final class FakeArr {
        var calls = 0
        var failing = false
    }

    @Test("Reloading swaps in a fresh first batch, and keeps the old rows when the arr is unreachable")
    func reloadKeepsLastGoodRows() async {
        let arr = FakeArr()
        let feed = HistoryFeed(sources: [.radarr], rowsPerBatch: 2) { _, _ in
            arr.calls += 1
            if arr.failing { return HistoryResult(items: [], error: "offline") }
            return HistoryResult(items: Self.plainPage(arr.calls, rows: 2), hasMore: true, error: nil)
        }
        await feed.load()
        #expect(feed.items.map(\.id) == ["p1-r0", "p1-r1"])
        await feed.load()
        #expect(feed.items.map(\.id) == ["p2-r0", "p2-r1"])
        arr.failing = true
        await feed.load()
        #expect(feed.items.map(\.id) == ["p2-r0", "p2-r1"])
        #expect(feed.error == nil)
    }

    @Test("An arr that fails with nothing loaded surfaces its error and stops")
    func errorWhenNothingLoaded() async {
        let feed = HistoryFeed(sources: [.sonarr]) { _, _ in
            HistoryResult(items: [], error: "unreachable")
        }
        await feed.load()
        #expect(feed.items.isEmpty)
        #expect(feed.error == "unreachable")
        #expect(!feed.hasMore)
    }
}
