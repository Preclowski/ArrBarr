import Testing
import Foundation
@testable import ArrCore

@Suite("ConfigStore.normalizeArrOrder")
struct ArrOrderMigrationTests {
    @Test("Fresh install returns the canonical default order")
    @MainActor
    func freshInstall() {
        let result = ConfigStore.normalizeArrOrder(nil)
        #expect(result == ConfigStore.defaultArrOrder)
    }

    @Test("Pre-0.7 stored order without tonight/needsyou gets both prepended")
    @MainActor
    func legacyMigration() {
        let result = ConfigStore.normalizeArrOrder(["radarr", "sonarr", "lidarr"])
        // tonight is inserted last so it ends up at index 0; needsyou at index 1;
        // whisparr is appended at the end (new key migration).
        #expect(result == ["tonight", "needsyou", "radarr", "sonarr", "lidarr", "whisparr"])
    }

    @Test("Stored order with only needsyou prepends just tonight")
    @MainActor
    func partialMigration() {
        let result = ConfigStore.normalizeArrOrder(["needsyou", "sonarr", "radarr", "lidarr"])
        #expect(result == ["tonight", "needsyou", "sonarr", "radarr", "lidarr", "whisparr"])
    }

    @Test("User custom order is preserved when complete")
    @MainActor
    func customOrderPreserved() {
        let custom = ["sonarr", "tonight", "lidarr", "needsyou", "radarr", "whisparr"]
        let result = ConfigStore.normalizeArrOrder(custom)
        #expect(result == custom)
    }

    @Test("Unknown keys are dropped, missing keys appended")
    @MainActor
    func unknownKeys() {
        let result = ConfigStore.normalizeArrOrder(["radarr", "bogus", "sonarr"])
        // tonight + needsyou prepended, lidarr + whisparr appended, bogus dropped.
        #expect(result == ["tonight", "needsyou", "radarr", "sonarr", "lidarr", "whisparr"])
    }

    @Test("Duplicates are deduplicated, first occurrence wins")
    @MainActor
    func duplicates() {
        let result = ConfigStore.normalizeArrOrder(["radarr", "sonarr", "radarr", "lidarr"])
        #expect(result == ["tonight", "needsyou", "radarr", "sonarr", "lidarr", "whisparr"])
    }
}

@Suite("QueueViewModel.tonightSlice")
struct TonightSliceTests {
    private func upcoming(id: String, source: UpcomingItem.Source, in seconds: TimeInterval) -> UpcomingItem {
        UpcomingItem(
            id: id, source: source, title: id, subtitle: nil,
            airDate: Date().addingTimeInterval(seconds),
            releaseType: nil, hasFile: false, overview: nil
        )
    }

    @Test("Items inside the window are kept")
    @MainActor
    func insideWindow() {
        let items = [
            upcoming(id: "soon", source: .sonarr, in: 60 * 60),       // +1h
            upcoming(id: "later", source: .radarr, in: 6 * 3600),     // +6h
        ]
        let result = QueueViewModel.tonightSlice(from: items, hours: 12)
        #expect(result.map(\.id) == ["soon", "later"])
    }

    @Test("Items past the cutoff are excluded")
    @MainActor
    func outsideWindow() {
        let items = [
            upcoming(id: "soon", source: .sonarr, in: 60 * 60),
            upcoming(id: "tomorrow", source: .radarr, in: 30 * 3600),
        ]
        let result = QueueViewModel.tonightSlice(from: items, hours: 12)
        #expect(result.map(\.id) == ["soon"])
    }

    @Test("Items in the past are excluded")
    @MainActor
    func pastItems() {
        let items = [
            upcoming(id: "past", source: .sonarr, in: -60 * 60),
            upcoming(id: "future", source: .radarr, in: 60 * 60),
        ]
        let result = QueueViewModel.tonightSlice(from: items, hours: 12)
        #expect(result.map(\.id) == ["future"])
    }

    @Test("24h window pulls in items 12h-24h out")
    @MainActor
    func wideWindow() {
        let items = [
            upcoming(id: "evening", source: .sonarr, in: 6 * 3600),
            upcoming(id: "next-night", source: .radarr, in: 23 * 3600),
        ]
        let result = QueueViewModel.tonightSlice(from: items, hours: 24)
        #expect(result.map(\.id) == ["evening", "next-night"])
    }

    @Test("Empty input returns empty result")
    @MainActor
    func empty() {
        #expect(QueueViewModel.tonightSlice(from: [], hours: 12).isEmpty)
    }
}

@Suite("QueueViewModel.computeNeedsYou")
struct ComputeNeedsYouTests {
    private func item(_ id: String, source: QueueItem.Source, status: QueueItem.Status) -> QueueItem {
        QueueItem(
            id: id, source: source, arrQueueId: 0,
            downloadId: nil, downloadProtocol: .unknown,
            downloadClient: nil, indexer: nil,
            title: id, subtitle: nil,
            status: status, progress: 0, sizeTotal: 0,
            sizeLeft: 0, timeLeft: nil,
            customFormats: [], customFormatScore: 0,
            quality: nil, isUpgrade: false,
            contentSlug: nil
        )
    }

    @Test("Failed and warning items are surfaced; healthy items are ignored")
    @MainActor
    func filtersByStatus() {
        let radarr = [
            item("r-fail", source: .radarr, status: .failed),
            item("r-ok", source: .radarr, status: .downloading),
        ]
        let sonarr = [item("s-warn", source: .sonarr, status: .warning)]
        let lidarr = [item("l-ok", source: .lidarr, status: .completed)]

        let result = QueueViewModel.computeNeedsYou(
            queues: [.radarr: radarr, .sonarr: sonarr, .lidarr: lidarr],
            errors: [:],
            health: .empty,
            showWarnings: true
        )
        #expect(result.map(\.id) == ["needsyou.r-fail", "needsyou.s-warn"])
    }

    @Test("Warning health records are hidden when showWarnings is off")
    @MainActor
    func benignHealthIgnored() {
        let health = HealthResult(
            radarr: [ArrHealthRecord(source: "IndexerStatusCheck", type: "warning",
                                     message: "Indexer X is down", wikiUrl: nil)],
            sonarr: [],
            lidarr: []
        )
        let result = QueueViewModel.computeNeedsYou(queues: [:], errors: [:], health: health, showWarnings: false)
        #expect(result.isEmpty)
    }

    @Test("Warning health records ARE surfaced when showWarnings is on")
    @MainActor
    func warningHealthSurfacedWhenEnabled() {
        let health = HealthResult(
            radarr: [ArrHealthRecord(source: "IndexerStatusCheck", type: "warning",
                                     message: "Indexer X is down", wikiUrl: nil)],
            sonarr: [],
            lidarr: []
        )
        let result = QueueViewModel.computeNeedsYou(queues: [:], errors: [:], health: health, showWarnings: true)
        #expect(result.count == 1)
        #expect(result.first?.source == .radarr)
        #expect(result.first?.detailLines == ["Indexer X is down"])
    }

    @Test("Error-level health records ARE surfaced even when showWarnings is off")
    @MainActor
    func errorHealthSurfaced() {
        let health = HealthResult(
            radarr: [ArrHealthRecord(source: "DownloadClientCheck", type: "error",
                                     message: "Download clients unavailable", wikiUrl: nil)],
            sonarr: [],
            lidarr: []
        )
        let result = QueueViewModel.computeNeedsYou(queues: [:], errors: [:], health: health, showWarnings: false)
        #expect(result.count == 1)
        #expect(result.first?.item == nil)
        #expect(result.first?.source == .radarr)
        #expect(result.first?.detailLines == ["Download clients unavailable"])
    }

    @Test("A per-arr fetch error is surfaced as an arr issue so an empty queue is explained")
    @MainActor
    func fetchErrorSurfaced() {
        let result = QueueViewModel.computeNeedsYou(
            queues: [:],
            errors: [.radarr: "HTTP 500"],
            health: .empty,
            showWarnings: false
        )
        #expect(result.count == 1)
        #expect(result.first?.item == nil)
        #expect(result.first?.source == .radarr)
        #expect(result.first?.detailLines == ["HTTP 500"])
    }

    @Test("Multiple problems for one arr group into a single entry, stacked")
    @MainActor
    func arrIssuesGroupedPerSource() {
        let health = HealthResult(
            radarr: [],
            sonarr: [
                ArrHealthRecord(source: "DownloadClientCheck", type: "error",
                                message: "Download clients unavailable", wikiUrl: nil),
                ArrHealthRecord(source: "ImportListCheck", type: "error",
                                message: "Lists unavailable", wikiUrl: nil),
            ],
            lidarr: []
        )
        let result = QueueViewModel.computeNeedsYou(
            queues: [:],
            errors: [.sonarr: "HTTP 500"],
            health: health,
            showWarnings: false
        )
        // One grouped Sonarr entry, all three problems stacked beneath it.
        #expect(result.count == 1)
        #expect(result.first?.source == .sonarr)
        #expect(result.first?.detailLines == ["HTTP 500", "Download clients unavailable", "Lists unavailable"])
    }

    @Test("Empty inputs return empty")
    @MainActor
    func empty() {
        let result = QueueViewModel.computeNeedsYou(queues: [:], errors: [:], health: .empty, showWarnings: true)
        #expect(result.isEmpty)
    }

    @Test("Subtitle reflects warning vs failed status")
    @MainActor
    func subtitleByStatus() {
        let result = QueueViewModel.computeNeedsYou(
            queues: [
                .radarr: [item("warn", source: .radarr, status: .warning)],
                .sonarr: [item("fail", source: .sonarr, status: .failed)],
            ],
            errors: [:],
            health: .empty,
            showWarnings: true
        )
        #expect(result.count == 2)
        let warning = result.first { $0.id == "needsyou.warn" }
        let failed = result.first { $0.id == "needsyou.fail" }
        #expect(warning?.subtitle == "queue.manualImportRequired.button")
        #expect(failed?.subtitle == QueueItem.Status.failed.displayName)
    }
}
