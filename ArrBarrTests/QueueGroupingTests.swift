import Testing
import Foundation
@testable import ArrBarr

@Suite("QueueGrouping")
struct QueueGroupingTests {
    private func item(
        id: String,
        downloadId: String?,
        title: String = "Test",
        subtitle: String? = nil
    ) -> QueueItem {
        QueueItem(
            id: id,
            source: .sonarr,
            arrQueueId: id.hashValue,
            downloadId: downloadId,
            downloadProtocol: .torrent,
            downloadClient: nil,
            indexer: nil,
            title: title,
            subtitle: subtitle,
            releaseName: nil,
            status: .downloading,
            progress: 0.5,
            sizeTotal: 0,
            sizeLeft: 0,
            timeLeft: nil,
            customFormats: [],
            customFormatScore: 0,
            quality: nil,
            isUpgrade: false,
            contentSlug: nil
        )
    }

    @Test("Empty input returns empty entries")
    func empty() {
        #expect(QueueGrouping.group([]).isEmpty)
    }

    @Test("All distinct downloadIds → all singletons")
    func allDistinct() {
        let items = [
            item(id: "1", downloadId: "a"),
            item(id: "2", downloadId: "b"),
            item(id: "3", downloadId: "c"),
        ]
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 3)
        for entry in entries {
            switch entry {
            case .single: break
            case .group: Issue.record("Expected all singletons, got a group")
            }
        }
    }

    @Test("Two items sharing a downloadId become one group")
    func sharedId() {
        let items = [
            item(id: "1", downloadId: "shared", subtitle: "S01E01"),
            item(id: "2", downloadId: "shared", subtitle: "S01E02"),
        ]
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 1)
        guard case .group(let g) = entries[0] else {
            Issue.record("Expected a group, got singleton")
            return
        }
        #expect(g.id == "shared")
        #expect(g.memberCount == 2)
    }

    @Test("Mixed input preserves order: singleton, group, singleton")
    func mixedOrder() {
        let items = [
            item(id: "solo1", downloadId: "a"),
            item(id: "pack1", downloadId: "pack"),
            item(id: "pack2", downloadId: "pack"),
            item(id: "solo2", downloadId: "b"),
        ]
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 3)
        if case .single(let s) = entries[0] { #expect(s.id == "solo1") } else { Issue.record("entry 0 not single") }
        if case .group(let g) = entries[1] { #expect(g.memberCount == 2 && g.id == "pack") } else { Issue.record("entry 1 not group") }
        if case .single(let s) = entries[2] { #expect(s.id == "solo2") } else { Issue.record("entry 2 not single") }
    }

    @Test("Bucket of one member stays a singleton, not a group of 1")
    func singleMemberBucket() {
        let items = [item(id: "1", downloadId: "only")]
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 1)
        if case .group = entries[0] {
            Issue.record("A bucket with one member should stay as .single")
        }
    }

    @Test("Items with nil/empty downloadId always render as singletons")
    func keylessItems() {
        let items = [
            item(id: "noId", downloadId: nil),
            item(id: "emptyId", downloadId: ""),
            item(id: "real1", downloadId: "shared"),
            item(id: "real2", downloadId: "shared"),
        ]
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 3)
        if case .single(let s) = entries[0] { #expect(s.id == "noId") } else { Issue.record("entry 0 not single") }
        if case .single(let s) = entries[1] { #expect(s.id == "emptyId") } else { Issue.record("entry 1 not single") }
        if case .group(let g) = entries[2] { #expect(g.memberCount == 2) } else { Issue.record("entry 2 not group") }
    }

    @Test("Group's representative is the first member in input order")
    func representativeIsFirst() {
        let items = [
            item(id: "first", downloadId: "shared"),
            item(id: "second", downloadId: "shared"),
            item(id: "third", downloadId: "shared"),
        ]
        let entries = QueueGrouping.group(items)
        guard case .group(let g) = entries.first else {
            Issue.record("Expected a group")
            return
        }
        #expect(g.representative.id == "first")
        #expect(g.items.map(\.id) == ["first", "second", "third"])
    }
}
