import Testing
import Foundation
@testable import ArrBarr

@Suite("QueueGrouping")
struct QueueGroupingTests {
    private func item(
        id: String,
        downloadId: String?,
        title: String = "Test",
        subtitle: String? = nil,
        source: QueueItem.Source = .sonarr,
        quality: String? = nil,
        releaseGroup: String? = nil,
        customFormats: [String] = []
    ) -> QueueItem {
        QueueItem(
            id: id,
            source: source,
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
            customFormats: customFormats,
            customFormatScore: 0,
            quality: quality,
            releaseGroup: releaseGroup,
            isUpgrade: false,
            contentSlug: nil
        )
    }

    /// Helper to build a fingerprint-eligible Sonarr episode. All optional
    /// arguments default to values that make the episode mergeable; pass an
    /// override to break a single dimension and verify the rule under test.
    private func episode(
        id: String,
        season: Int = 1,
        episodeNumber: Int,
        title: String = "Show",
        downloadId: String? = nil,
        quality: String = "WEB-DL 1080p",
        releaseGroup: String = "GROUP",
        customFormats: [String] = ["x264", "AAC"]
    ) -> QueueItem {
        item(
            id: id,
            downloadId: downloadId ?? id,
            title: title,
            subtitle: String(format: "S%02dE%02d", season, episodeNumber),
            quality: quality,
            releaseGroup: releaseGroup,
            customFormats: customFormats
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

    // MARK: - Virtual season grouping

    @Test("Pack groups carry kind == .pack")
    func packKind() {
        let items = [
            item(id: "1", downloadId: "shared"),
            item(id: "2", downloadId: "shared"),
        ]
        guard case .group(let g) = QueueGrouping.group(items)[0] else {
            Issue.record("expected group"); return
        }
        #expect(g.kind == .pack)
    }

    @Test("3+ matching episodes with distinct downloadIds form a virtual group")
    func virtualBundleFormsAtThreshold() {
        let items = (1...3).map { episode(id: "v\($0)", episodeNumber: $0) }
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 1)
        guard case .group(let g) = entries[0] else {
            Issue.record("expected group"); return
        }
        #expect(g.kind == .virtual)
        #expect(g.memberCount == 3)
    }

    @Test("Two matching episodes stay as singletons (below threshold)")
    func virtualBelowThresholdStaysSingletons() {
        let items = (1...2).map { episode(id: "v\($0)", episodeNumber: $0) }
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 2)
        for entry in entries {
            if case .group = entry { Issue.record("should not group below threshold") }
        }
    }

    @Test("Different release groups break the virtual bundle")
    func virtualNeedsSameReleaseGroup() {
        let items = [
            episode(id: "v1", episodeNumber: 1, releaseGroup: "ALPHA"),
            episode(id: "v2", episodeNumber: 2, releaseGroup: "BETA"),
            episode(id: "v3", episodeNumber: 3, releaseGroup: "GAMMA"),
        ]
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 3)
        for entry in entries {
            if case .group = entry { Issue.record("different release groups must not collapse") }
        }
    }

    @Test("Different seasons break the virtual bundle")
    func virtualNeedsSameSeason() {
        let items = [
            episode(id: "v1", season: 1, episodeNumber: 1),
            episode(id: "v2", season: 2, episodeNumber: 1),
            episode(id: "v3", season: 3, episodeNumber: 1),
        ]
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 3)
        for entry in entries {
            if case .group = entry { Issue.record("different seasons must not collapse") }
        }
    }

    @Test("Different qualities break the virtual bundle")
    func virtualNeedsSameQuality() {
        let items = [
            episode(id: "v1", episodeNumber: 1, quality: "WEB-DL 1080p"),
            episode(id: "v2", episodeNumber: 2, quality: "WEB-DL 720p"),
            episode(id: "v3", episodeNumber: 3, quality: "Bluray-1080p"),
        ]
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 3)
    }

    @Test("Different custom formats break the virtual bundle")
    func virtualNeedsSameCustomFormats() {
        let items = [
            episode(id: "v1", episodeNumber: 1, customFormats: ["x264"]),
            episode(id: "v2", episodeNumber: 2, customFormats: ["x265"]),
            episode(id: "v3", episodeNumber: 3, customFormats: ["x264", "AAC"]),
        ]
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 3)
    }

    @Test("Custom format order doesn't matter — sorted comparison")
    func virtualCustomFormatOrderInsensitive() {
        let items = [
            episode(id: "v1", episodeNumber: 1, customFormats: ["x264", "AAC"]),
            episode(id: "v2", episodeNumber: 2, customFormats: ["AAC", "x264"]),
            episode(id: "v3", episodeNumber: 3, customFormats: ["x264", "AAC"]),
        ]
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 1)
        if case .group(let g) = entries[0] { #expect(g.kind == .virtual) }
    }

    @Test("Missing release group disables virtual grouping")
    func virtualSkipsWhenReleaseGroupMissing() {
        let items: [QueueItem] = (1...3).map {
            item(
                id: "v\($0)", downloadId: "v\($0)",
                title: "Show", subtitle: String(format: "S01E%02d", $0),
                quality: "WEB-DL 1080p", releaseGroup: nil,
                customFormats: ["x264"]
            )
        }
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 3)
    }

    @Test("Non-sonarr items never form virtual groups")
    func virtualIsSonarrOnly() {
        let items = (1...3).map {
            item(
                id: "r\($0)", downloadId: "r\($0)",
                title: "Movie",
                subtitle: String(format: "S01E%02d", $0),
                source: .radarr,
                quality: "WEB-DL 1080p",
                releaseGroup: "GROUP",
                customFormats: ["x264"]
            )
        }
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 3)
    }

    @Test("Real pack and a virtual bundle coexist independently")
    func packAndVirtualCoexist() {
        // 2-episode real pack from one downloadId, plus 3 virtual-eligible
        // siblings of a different series. Expect: one .pack + one .virtual.
        var items: [QueueItem] = [
            episode(id: "p1", episodeNumber: 1, title: "Packed", downloadId: "shared"),
            episode(id: "p2", episodeNumber: 2, title: "Packed", downloadId: "shared"),
        ]
        items.append(contentsOf: (1...3).map {
            episode(id: "v\($0)", episodeNumber: $0, title: "Virtual")
        })
        let entries = QueueGrouping.group(items)
        #expect(entries.count == 2)
        guard case .group(let pack) = entries[0],
              case .group(let virtual) = entries[1]
        else { Issue.record("expected two groups"); return }
        #expect(pack.kind == .pack)
        #expect(pack.memberCount == 2)
        #expect(virtual.kind == .virtual)
        #expect(virtual.memberCount == 3)
    }
}
