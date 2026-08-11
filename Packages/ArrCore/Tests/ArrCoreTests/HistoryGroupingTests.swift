import Foundation
import Testing
@testable import ArrCore

@Suite("History import-batch grouping")
struct HistoryGroupingTests {
    /// A per-file import row as the arr clients produce it.
    private func row(
        id: String, source: QueueItem.Source = .lidarr, minutesAgo: Double = 0,
        event: HistoryItem.EventType = .imported, subtitle: String? = "Album",
        quality: String? = "FLAC", hint: HistoryItem.GroupHint?
    ) -> HistoryItem {
        HistoryItem(
            id: id, source: source,
            date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
            eventType: event, title: "Artist", subtitle: subtitle,
            sourceTitle: "Release-DEMO", quality: quality,
            customFormats: [], customFormatScore: 0, groupHint: hint
        )
    }

    @Test("A whole-album import folds into one row carrying the batch size")
    func albumBatchFolds() {
        let hint = HistoryItem.GroupHint(key: "dl1|album-15")
        let items = [
            row(id: "grab", minutesAgo: 1, event: .grabbed, hint: nil),
            row(id: "t1", minutesAgo: 2, hint: hint),
            row(id: "t2", minutesAgo: 3, hint: hint),
            row(id: "t3", minutesAgo: 4, hint: hint),
        ]
        let out = HistoryItem.collapsingImportBatches(items)
        #expect(out.map(\.id) == ["grab", "t1"])
        #expect(out[1].groupedCount == 3)
        #expect(out[1].subtitle == "Album")
        #expect(out[1].date == items[1].date)
    }

    @Test("A season pack swaps the per-episode subtitle for the season label")
    func seasonPackSubtitle() {
        let hint = HistoryItem.GroupHint(key: "dl2|s2", collapsedSubtitle: "Season 2")
        let items = [
            row(id: "e1", source: .sonarr, minutesAgo: 1, subtitle: "S02E08 · Finale", hint: hint),
            row(id: "e2", source: .sonarr, minutesAgo: 2, subtitle: "S02E07", hint: hint),
        ]
        let out = HistoryItem.collapsingImportBatches(items)
        #expect(out.count == 1)
        #expect(out[0].subtitle == "Season 2")
        #expect(out[0].groupedCount == 2)
    }

    @Test("Rows of differing quality never merge")
    func mixedQualityStaysApart() {
        let hint = HistoryItem.GroupHint(key: "dl3|album-1")
        let items = [
            row(id: "a", quality: "FLAC", hint: hint),
            row(id: "b", quality: "MP3-320", hint: hint),
        ]
        let out = HistoryItem.collapsingImportBatches(items)
        #expect(out.map(\.id) == ["a", "b"])
        #expect(out.allSatisfy { $0.groupedCount == 1 })
    }

    @Test("A lone hinted row and non-import events pass through untouched")
    func singletonsAndOtherEventsUntouched() {
        let hint = HistoryItem.GroupHint(key: "dl4|album-2")
        let items = [
            row(id: "solo", hint: hint),
            row(id: "del1", event: .deleted, hint: hint),
            row(id: "del2", event: .deleted, hint: hint),
            row(id: "plain", hint: nil),
        ]
        let out = HistoryItem.collapsingImportBatches(items)
        #expect(out == items)
    }

    @Test("Same group key on different sources never merges")
    func sourcesStayApart() {
        let hint = HistoryItem.GroupHint(key: "shared")
        let items = [
            row(id: "l", source: .lidarr, hint: hint),
            row(id: "s", source: .sonarr, hint: hint),
        ]
        #expect(HistoryItem.collapsingImportBatches(items).count == 2)
    }
}
