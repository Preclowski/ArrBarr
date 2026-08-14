import Testing
import Foundation
@testable import ArrCore

@Suite("QueueTitleGrouping")
struct QueueTitleGroupingTests {
    private func item(
        id: String,
        title: String,
        source: QueueItem.Source = .sonarr,
        entityId: Int? = nil,
        downloadId: String? = nil,
        sizeTotal: Int64 = 0,
        sizeLeft: Int64 = 0,
        progress: Double = 0.5
    ) -> QueueItem {
        QueueItem(
            id: id,
            source: source,
            arrQueueId: id.hashValue,
            downloadId: downloadId ?? id,
            downloadProtocol: .torrent,
            downloadClient: nil,
            title: title,
            subtitle: nil,
            status: .downloading,
            progress: progress,
            sizeTotal: sizeTotal,
            sizeLeft: sizeLeft,
            timeLeft: nil,
            customFormats: [],
            customFormatScore: 0,
            quality: nil,
            isUpgrade: false,
            contentSlug: nil,
            entityId: entityId
        )
    }

    private func entries(_ items: [QueueItem]) -> [QueueRowEntry] {
        items.map { .single($0) }
    }

    @Test("Singletons pass through untouched")
    func singletonsPassThrough() {
        let rows = QueueGrouping.groupByTitle(entries([
            item(id: "a", title: "Alpha", entityId: 1),
            item(id: "b", title: "Beta", entityId: 2),
        ]))
        #expect(rows.count == 2)
        for row in rows {
            guard case .entry = row else {
                Issue.record("expected pass-through entry, got \(row)")
                return
            }
        }
    }

    @Test("Two entries of one title form a group at the first member's position")
    func groupsAtFirstPosition() {
        let rows = QueueGrouping.groupByTitle(entries([
            item(id: "a", title: "Alpha", entityId: 1),
            item(id: "b", title: "Beta", entityId: 2),
            item(id: "c", title: "Alpha", entityId: 1),
        ]))
        #expect(rows.count == 2)
        guard case .titleGroup(let group) = rows[0] else {
            Issue.record("expected the group first (position of its first member)")
            return
        }
        #expect(group.downloadCount == 2)
        #expect(group.allItems.map(\.id) == ["a", "c"])
        guard case .entry(let single) = rows[1], case .single(let beta) = single else {
            Issue.record("expected Beta as a pass-through entry")
            return
        }
        #expect(beta.id == "b")
    }

    @Test("Same entity id across different arrs never groups")
    func sourcesDoNotCollide() {
        let rows = QueueGrouping.groupByTitle(entries([
            item(id: "a", title: "Alpha", source: .sonarr, entityId: 7),
            item(id: "b", title: "Alpha", source: .radarr, entityId: 7),
        ]))
        #expect(rows.count == 2)
    }

    @Test("Missing entityId falls back to normalized title")
    func titleFallback() {
        let rows = QueueGrouping.groupByTitle(entries([
            item(id: "a", title: "Alpha"),
            item(id: "b", title: "alpha"),
        ]))
        #expect(rows.count == 1)
        guard case .titleGroup(let group) = rows[0] else {
            Issue.record("expected a title group")
            return
        }
        #expect(group.downloadCount == 2)
    }

    @Test("A season pack counts as one download inside its title group")
    func packIsOneDownload() {
        let pack = QueueGroup(id: "pack", items: [
            item(id: "p1", title: "Alpha", entityId: 1, downloadId: "pack"),
            item(id: "p2", title: "Alpha", entityId: 1, downloadId: "pack"),
        ])
        let rows = QueueGrouping.groupByTitle([
            .group(pack),
            .single(item(id: "s", title: "Alpha", entityId: 1)),
        ])
        #expect(rows.count == 1)
        guard case .titleGroup(let group) = rows[0] else {
            Issue.record("expected a title group")
            return
        }
        #expect(group.downloadCount == 2)     // pack = 1, single = 1
        #expect(group.allItems.count == 3)    // but 3 underlying queue items
    }

    @Test("Aggregate progress is size-weighted")
    func aggregateProgress() {
        let group = QueueTitleGroup(id: "k", entries: entries([
            item(id: "a", title: "Alpha", sizeTotal: 900, sizeLeft: 0),
            item(id: "b", title: "Alpha", sizeTotal: 100, sizeLeft: 100),
        ]))
        #expect(abs(group.aggregateProgress - 0.9) < 0.0001)
    }

    @Test("Aggregate progress falls back to mean when sizes are unknown")
    func aggregateProgressFallback() {
        let group = QueueTitleGroup(id: "k", entries: entries([
            item(id: "a", title: "Alpha", progress: 0.2),
            item(id: "b", title: "Alpha", progress: 0.8),
        ]))
        #expect(abs(group.aggregateProgress - 0.5) < 0.0001)
    }
}
