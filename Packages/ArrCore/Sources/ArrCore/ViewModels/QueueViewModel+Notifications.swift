import Foundation

extension QueueViewModel {
    // MARK: - Notifications

    /// Errored arrs are passed through so a transient empty result never re-notifies a still-queued item.
    /// Errors only, never warnings: a notification stream that cries wolf gets silenced wholesale.
    func notifyNewHealthIssues(_ result: HealthResult) {
        guard configStore.notifyHealth else {
            // Still fold the records in, so enabling the setting later announces only what breaks next.
            for source in QueueItem.Source.allCases where configuredArrs.contains(source) && !result.failed.contains(source) {
                _ = healthTracker.newIssues(for: source, records: result.records(for: source))
            }
            persistHealthTracker()
            return
        }
        // A failed read says nothing about which issues are gone, so the tracker only hears reachable sources.
        for source in QueueItem.Source.allCases where configuredArrs.contains(source) && !result.failed.contains(source) {
            let errors = result.records(for: source).filter {
                $0.type?.lowercased() == "error" && $0.message?.isEmpty == false
            }
            for record in healthTracker.newIssues(for: source, records: errors) {
                coalescer.postHealthIssue(source: source, message: record.message ?? "")
            }
        }
        persistHealthTracker()
    }

    func notifyNewItems(source: QueueItem.Source, items: [QueueItem], errored: Bool) {
        guard !errored else { return }
        let newItems = notificationTracker.newItems(for: source, items: items)
        persistNotificationTracker()
        for item in newItems {
            let allowed: Bool = switch item.source {
            case .radarr: configStore.notifyRadarr
            case .sonarr: configStore.notifySonarr
            case .lidarr: configStore.notifyLidarr
            case .whisparr: false  // no notify toggle for Whisparr
            }
            if allowed { coalescer.enqueue(item) }
        }
    }
}
