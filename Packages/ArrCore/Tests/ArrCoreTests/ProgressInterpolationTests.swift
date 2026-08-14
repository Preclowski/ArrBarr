import Testing
import Foundation
@testable import ArrCore

@Suite("Progress interpolation")
struct ProgressInterpolationTests {

    private func item(
        status: QueueItem.Status = .downloading,
        progress: Double = 0.5,
        sizeTotal: Int64 = 1_000_000,
        timeLeft: String? = nil,
        speed: Int64? = nil
    ) -> QueueItem {
        QueueItem(
            id: "radarr-1", source: .radarr, arrQueueId: 1,
            downloadId: "abc", downloadProtocol: .usenet,
            downloadClient: "SABnzbd", title: "Test",
            subtitle: nil, status: status, progress: progress,
            sizeTotal: sizeTotal, sizeLeft: Int64(Double(sizeTotal) * (1 - progress)),
            timeLeft: timeLeft, downloadSpeed: speed,
            customFormats: [], customFormatScore: 0, quality: nil,
            isUpgrade: false, contentSlug: nil
        )
    }

    @Test("The client's byte rate drives the estimate when it reports one")
    func rateFromClientSpeed() {
        // 10 kB/s of a 1 MB download = 1% per second.
        let row = item(speed: 10_000)
        let rate = try! #require(row.progressRatePerSecond)
        #expect(abs(rate - 0.01) < 0.0001)

        let start = Date()
        let after10s = row.interpolatedProgress(at: start.addingTimeInterval(10), measuredAt: start)
        #expect(abs(after10s - 0.6) < 0.0001)
    }

    @Test("Without a client speed the arr's ETA is enough")
    func rateFromTimeLeft() {
        // SABnzbd reports no per-slot speed, so this is the path that actually
        // runs on a usenet stack.
        let row = item(progress: 0.5, timeLeft: "00:01:40")   // 100 s for the last half
        let rate = try! #require(row.progressRatePerSecond)
        #expect(abs(rate - 0.005) < 0.0001)

        let start = Date()
        #expect(abs(row.interpolatedProgress(at: start.addingTimeInterval(50), measuredAt: start) - 0.75) < 0.0001)
    }

    @Test("Only a downloading row moves", arguments: [
        QueueItem.Status.paused, .queued, .completed, .warning, .failed,
    ])
    func onlyDownloadingInterpolates(_ status: QueueItem.Status) {
        let row = item(status: status, speed: 10_000)
        #expect(row.progressRatePerSecond == nil)
        #expect(!row.isInterpolatingProgress)
        let start = Date()
        #expect(row.interpolatedProgress(at: start.addingTimeInterval(30), measuredAt: start) == row.progress)
    }

    @Test("The estimate never claims completion")
    func neverReachesOneHundred() {
        // Fast enough to "finish" twice over inside the window.
        let row = item(progress: 0.95, speed: 500_000)
        let start = Date()
        let drawn = row.interpolatedProgress(at: start.addingTimeInterval(30), measuredAt: start)
        #expect(drawn <= QueueItem.completionCeiling)
        #expect(drawn < 1)
    }

    @Test("A stale reading stops being extrapolated from")
    func expiresRatherThanDrifting() {
        let row = item(speed: 10_000)
        let start = Date()
        // Inside the window it moves…
        #expect(row.interpolatedProgress(at: start.addingTimeInterval(30), measuredAt: start) > row.progress)
        // …past it the bar holds at the last honest position rather than
        // inventing progress for a download that may have died.
        let stale = start.addingTimeInterval(QueueItem.maxExtrapolation + 1)
        #expect(row.interpolatedProgress(at: stale, measuredAt: start) == row.progress)
    }

    @Test("A clock that runs backwards changes nothing")
    func backwardsClock() {
        let row = item(speed: 10_000)
        let start = Date()
        #expect(row.interpolatedProgress(at: start.addingTimeInterval(-5), measuredAt: start) == row.progress)
        // `.distantPast` is what every non-interpolating call site passes.
        #expect(row.interpolatedProgress(at: .distantPast, measuredAt: start) == row.progress)
    }

    @Test("timeleft parses hours, minutes, seconds and .NET day spans")
    func timeLeftParsing() {
        #expect(QueueItem.seconds(fromTimeLeft: "00:01:40") == 100)
        #expect(QueueItem.seconds(fromTimeLeft: "01:00:00") == 3_600)
        #expect(QueueItem.seconds(fromTimeLeft: "1.00:00:00") == 86_400)
        #expect(QueueItem.seconds(fromTimeLeft: "00:00:10.5") == 10)
        // A finished or absent ETA is not a rate.
        #expect(QueueItem.seconds(fromTimeLeft: "00:00:00") == nil)
        #expect(QueueItem.seconds(fromTimeLeft: nil) == nil)
        #expect(QueueItem.seconds(fromTimeLeft: "soon") == nil)
    }

    @Test("A group's aggregate matches the measured one until time passes")
    func aggregateStartsFromTheMeasuredValue() {
        let rows = [item(progress: 0.25, sizeTotal: 1_000_000, speed: 10_000),
                    item(progress: 0.75, sizeTotal: 3_000_000, speed: 30_000)]
        let group = QueueTitleGroup(id: "g", entries: rows.map { .single($0) })
        let start = Date()
        // The measured aggregate comes from remaining BYTES, which is what the
        // bar has always shown — interpolation only adds movement on top.
        #expect(abs(group.aggregateProgress(at: start, measuredAt: start) - group.aggregateProgress) < 0.0001)
        #expect(group.aggregateProgress(at: start.addingTimeInterval(10), measuredAt: start)
                > group.aggregateProgress)
    }
}
