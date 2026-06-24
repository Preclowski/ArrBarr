import Testing
@testable import ArrCore

@Suite("Download-client progress overlay")
struct DownloadProgressOverlayTests {
    private func item(_ id: String, downloadId: String?, progress: Double) -> QueueItem {
        QueueItem(
            id: id, source: .sonarr, arrQueueId: 1,
            downloadId: downloadId, downloadProtocol: .torrent,
            downloadClient: nil, indexer: nil,
            title: id, subtitle: nil,
            status: .downloading, progress: progress, sizeTotal: 100,
            sizeLeft: 50, timeLeft: nil,
            customFormats: [], customFormatScore: 0,
            quality: nil, isUpgrade: false,
            contentSlug: nil
        )
    }

    @Test("Client progress replaces the arr value, matched case-insensitively")
    func clientWins() {
        let items = [
            item("a", downloadId: "ABCDEF", progress: 0.10),  // arr says 10%
            item("b", downloadId: "nzo_1", progress: 0.20),   // no client entry
        ]
        let progress: [String: DownloadProgress] = [
            "abcdef": DownloadProgress(progress: 0.90),  // client says 90% (lowercased key)
        ]
        let out = QueueAggregator.overlay(items, with: progress)
        #expect(out[0].progress == 0.90)  // uppercase arr hash matched the lowercased client key
        #expect(out[1].progress == 0.20)  // no client entry → arr value kept (fallback)
    }

    @Test("No client progress at all → every item keeps its arr value")
    func emptyPassthrough() {
        let items = [item("a", downloadId: "x", progress: 0.33)]
        let out = QueueAggregator.overlay(items, with: [:])
        #expect(out[0].progress == 0.33)
    }

    @Test("An item without a downloadId can't be matched → arr value")
    func noDownloadId() {
        let items = [item("a", downloadId: nil, progress: 0.44)]
        let out = QueueAggregator.overlay(items, with: ["abcdef": DownloadProgress(progress: 0.9)])
        #expect(out[0].progress == 0.44)
    }

    @Test("DownloadProgress clamps out-of-range values to 0...1")
    func clamps() {
        #expect(DownloadProgress(progress: 1.5).progress == 1.0)
        #expect(DownloadProgress(progress: -0.2).progress == 0.0)
    }
}
