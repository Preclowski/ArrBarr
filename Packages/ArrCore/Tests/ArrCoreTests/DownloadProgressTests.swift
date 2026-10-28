import Testing
import MediaKit
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
        let progress: [String: DownloadTask] = [
            "abcdef": task("abcdef", progress: 0.90),  // client says 90% (lowercased key)
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
        let out = QueueAggregator.overlay(items, with: ["abcdef": task("abcdef", progress: 0.9)])
        #expect(out[0].progress == 0.44)
    }

    @Test("The client's pause/resume beats the arr's lagging status; arr-side states stay")
    func clientStatus() {
        var paused = item("a", downloadId: "x", progress: 0.4)
        paused.status = .paused
        var importing = item("b", downloadId: "y", progress: 1)
        importing.status = .importing
        let out = QueueAggregator.overlay([paused, importing], with: [
            "x": task("x", progress: 0.4),
            "y": task("y", progress: 1, state: .paused),
        ])
        #expect(out[0].status == .downloading)
        #expect(out[1].status == .importing)
    }

    @Test("A stalled or checking task lifts the arr's stale pause, and otherwise defers to the arr",
          arguments: [DownloadTask.State.stalled, .checking])
    func runningWithoutMoving(_ state: DownloadTask.State) {
        var paused = item("a", downloadId: "x", progress: 0.4)
        paused.status = .paused
        var queued = item("b", downloadId: "y", progress: 0.4)
        queued.status = .queued
        let out = QueueAggregator.overlay([paused, queued], with: [
            "x": task("x", progress: 0.4, state: state),
            "y": task("y", progress: 0.4, state: state),
        ])
        #expect(out[0].status == .downloading)
        #expect(out[1].status == .queued)
    }

    private func task(_ id: String, progress: Double, state: DownloadTask.State = .downloading) -> DownloadTask {
        DownloadTask(id: id, name: id, state: state, progress: progress, instance: InstanceID(.qbittorrent))
    }
}
