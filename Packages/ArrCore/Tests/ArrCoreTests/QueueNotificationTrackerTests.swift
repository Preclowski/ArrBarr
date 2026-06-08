import Testing
import Foundation
@testable import ArrCore

private func item(
    source: QueueItem.Source = .sonarr,
    queueId: Int,
    downloadId: String?,
    season: Int? = nil,
    episode: Int? = nil,
    title: String = "Supernatural"
) -> QueueItem {
    QueueItem(
        id: "\(source.rawValue)-\(queueId)",
        source: source, arrQueueId: queueId,
        downloadId: downloadId, downloadProtocol: .torrent,
        downloadClient: "qBittorrent",
        title: title, subtitle: nil,
        seasonNumber: season, episodeNumber: episode,
        status: .downloading, progress: 0.5,
        sizeTotal: 1000, sizeLeft: 500, timeLeft: nil,
        customFormats: [], customFormatScore: 0,
        quality: nil, isUpgrade: false,
        contentSlug: nil
    )
}

@Suite struct QueueNotificationTrackerTests {

    @Test("First successful fetch seeds silently — pre-existing items don't notify")
    func seedsSilently() {
        var tracker = QueueNotificationTracker()
        let new = tracker.newItems(
            perSource: [.sonarr: [item(queueId: 1, downloadId: "hashA")]],
            errored: []
        )
        #expect(new.isEmpty)
    }

    @Test("A genuinely new item notifies once, then not again")
    func notifiesNewItemOnce() {
        var tracker = QueueNotificationTracker()
        _ = tracker.newItems(perSource: [.sonarr: []], errored: [])  // seed empty

        let first = tracker.newItems(
            perSource: [.sonarr: [item(queueId: 1, downloadId: "hashA")]],
            errored: []
        )
        #expect(first.count == 1)

        let second = tracker.newItems(
            perSource: [.sonarr: [item(queueId: 1, downloadId: "hashA")]],
            errored: []
        )
        #expect(second.isEmpty)
    }

    // The headline regression: an item sits in the queue for days. A transient
    // fetch error returns an empty list for that arr. The next success must NOT
    // re-notify the still-present item.
    @Test("Transient fetch error does not re-notify a still-queued item")
    func transientErrorDoesNotRenotify() {
        var tracker = QueueNotificationTracker()
        let snapshot: [QueueItem.Source: [QueueItem]] = [
            .sonarr: [item(queueId: 1, downloadId: "hashA")]
        ]
        _ = tracker.newItems(perSource: snapshot, errored: [])  // seed: present, silent

        // Sonarr fetch fails → empty list + errored. Must be ignored.
        let duringError = tracker.newItems(perSource: [.sonarr: []], errored: [.sonarr])
        #expect(duringError.isEmpty)

        // Fetch recovers, item still there. Must stay silent.
        let afterRecovery = tracker.newItems(perSource: snapshot, errored: [])
        #expect(afterRecovery.isEmpty)
    }

    // Same as above but the empty result arrives WITHOUT being flagged errored
    // (e.g. the item momentarily drops out of the queue during a state
    // transition). Union accumulation must keep it remembered.
    @Test("Item briefly leaving the queue does not re-notify on return")
    func transientDropOutDoesNotRenotify() {
        var tracker = QueueNotificationTracker()
        let snapshot: [QueueItem.Source: [QueueItem]] = [
            .sonarr: [item(queueId: 1, downloadId: "hashA")]
        ]
        _ = tracker.newItems(perSource: snapshot, errored: [])  // seed

        _ = tracker.newItems(perSource: [.sonarr: []], errored: [])  // briefly gone
        let back = tracker.newItems(perSource: snapshot, errored: [])
        #expect(back.isEmpty)
    }

    // The arr re-assigns the queue record id (downloading → importing) but the
    // download-client hash is stable. Must not look new.
    @Test("Queue record-id churn with stable downloadId does not re-notify")
    func recordIdChurnDoesNotRenotify() {
        var tracker = QueueNotificationTracker()
        _ = tracker.newItems(
            perSource: [.sonarr: [item(queueId: 1, downloadId: "hashA")]],
            errored: []
        )
        // Same download, new record id.
        let churned = tracker.newItems(
            perSource: [.sonarr: [item(queueId: 99, downloadId: "hashA")]],
            errored: []
        )
        #expect(churned.isEmpty)
    }

    // The relaunch regression: a tracker persisted to disk and reloaded must
    // not re-announce items that are still queued.
    @Test("Persisted tracker survives a relaunch without re-notifying")
    func codableRoundTripDoesNotRenotify() throws {
        var tracker = QueueNotificationTracker()
        let snapshot: [QueueItem.Source: [QueueItem]] = [
            .sonarr: [item(queueId: 1, downloadId: "hashA")]
        ]
        _ = tracker.newItems(perSource: snapshot, errored: [])  // seed

        // Simulate quit + relaunch: encode, then decode into a fresh tracker.
        let data = try JSONEncoder().encode(tracker)
        var reloaded = try JSONDecoder().decode(QueueNotificationTracker.self, from: data)

        let afterRelaunch = reloaded.newItems(perSource: snapshot, errored: [])
        #expect(afterRelaunch.isEmpty)
    }

    // A download stuck in the queue behind thousands of others must never be
    // evicted by the FIFO cap, or it would re-notify.
    @Test("A long-stuck queued item is never evicted by the cap")
    func longStuckItemNeverEvicted() {
        var tracker = QueueNotificationTracker()
        let stuck = item(queueId: 1, downloadId: "stuck-hash")

        // Seed with the stuck item present.
        _ = tracker.newItems(perSource: [.sonarr: [stuck]], errored: [])

        // Churn far more than the cap of other downloads, with the stuck item
        // remaining in every snapshot.
        for n in 0..<(QueueNotificationTracker.capPerSource + 500) {
            let others = item(queueId: 1000 + n, downloadId: "other-\(n)")
            _ = tracker.newItems(perSource: [.sonarr: [stuck, others]], errored: [])
        }

        // The stuck item must still be remembered → no new notification.
        let again = tracker.newItems(perSource: [.sonarr: [stuck]], errored: [])
        #expect(again.isEmpty)
    }

    @Test("Each arr is seeded independently on its own first success")
    func perArrIndependentSeeding() {
        var tracker = QueueNotificationTracker()
        // First cycle: only Radarr succeeds; Sonarr errors.
        _ = tracker.newItems(
            perSource: [.radarr: [item(source: .radarr, queueId: 1, downloadId: "rad")]],
            errored: [.sonarr]
        )
        // Sonarr recovers for the first time — its pre-existing item should
        // seed silently, not notify.
        let sonarrFirst = tracker.newItems(
            perSource: [
                .radarr: [item(source: .radarr, queueId: 1, downloadId: "rad")],
                .sonarr: [item(source: .sonarr, queueId: 1, downloadId: "son")],
            ],
            errored: []
        )
        #expect(sonarrFirst.isEmpty)
    }
}
