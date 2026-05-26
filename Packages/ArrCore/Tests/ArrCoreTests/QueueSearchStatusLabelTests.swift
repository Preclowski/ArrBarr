import Testing
import Foundation
@testable import ArrCore

@Suite("QueueSearchStatusLabel")
struct QueueSearchStatusLabelTests {
    private func item(status: QueueItem.Status, progress: Double, timeLeft: String?) -> QueueItem {
        QueueItem(
            id: "x", source: .radarr, arrQueueId: 1, downloadId: nil,
            downloadProtocol: .unknown, downloadClient: nil, indexer: nil,
            title: "t", subtitle: nil,
            seasonNumber: nil, episodeNumber: nil, episodeTitle: nil,
            releaseName: nil,
            status: status, progress: progress, sizeTotal: 0,
            sizeLeft: 0, timeLeft: timeLeft,
            customFormats: [], customFormatScore: 0,
            quality: nil, releaseGroup: nil, isUpgrade: false,
            contentSlug: nil
        )
    }

    @Test("Downloading with progress and timeLeft renders percent + ETA")
    func downloadingWithEta() {
        let it = item(status: .downloading, progress: 0.624, timeLeft: "12 min")
        #expect(QueueSearchStatusLabel.label(for: it) == "62% · 12 min")
    }

    @Test("Downloading with progress but no timeLeft renders percent only")
    func downloadingNoEta() {
        let it = item(status: .downloading, progress: 0.05, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "5%")
    }

    @Test("Downloading with empty timeLeft string renders percent only")
    func downloadingEmptyEta() {
        let it = item(status: .downloading, progress: 0.5, timeLeft: "")
        #expect(QueueSearchStatusLabel.label(for: it) == "50%")
    }

    @Test("Downloading with zero progress renders 'downloading'")
    func downloadingZeroProgress() {
        let it = item(status: .downloading, progress: 0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "downloading")
    }

    @Test("Queued renders 'queued'")
    func queued() {
        let it = item(status: .queued, progress: 0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "queued")
    }

    @Test("Paused renders 'paused'")
    func paused() {
        let it = item(status: .paused, progress: 0.42, timeLeft: "1 hr")
        #expect(QueueSearchStatusLabel.label(for: it) == "paused")
    }

    @Test("Importing renders 'importing'")
    func importing() {
        let it = item(status: .importing, progress: 1.0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "importing")
    }

    @Test("Completed renders 'completed'")
    func completed() {
        let it = item(status: .completed, progress: 1.0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "completed")
    }

    @Test("Warning renders 'warning'")
    func warning() {
        let it = item(status: .warning, progress: 0.3, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "warning")
    }

    @Test("Failed renders 'failed'")
    func failed() {
        let it = item(status: .failed, progress: 0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "failed")
    }

    @Test("Unknown falls back to 'queued'")
    func unknownFallback() {
        let it = item(status: .unknown, progress: 0, timeLeft: nil)
        #expect(QueueSearchStatusLabel.label(for: it) == "queued")
    }
}
