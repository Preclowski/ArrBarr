import Foundation

/// Mutable layer over the static queue fixtures — the demo's stand-in for a
/// download client.
///
/// The demo queue is a computed array rebuilt from `DemoMocks` on every refresh,
/// so an optimistic pause or cancel was wiped by the next poll a few seconds
/// later: the two actions the app exists for looked broken in the one build
/// meant to show them off. Actions land here instead, and every demo refresh
/// reads the fixtures back through `apply`.
///
/// In-memory on purpose. A demo that remembers which downloads you cancelled
/// last week isn't a demo — relaunching should hand the next viewer the curated
/// queue exactly as designed.
@MainActor
enum DemoQueueState {
    private static var statusOverrides: [String: QueueItem.Status] = [:]
    private static var removed: Set<String> = []

    /// The fixtures as the user has left them.
    static func apply(_ items: [QueueItem]) -> [QueueItem] {
        guard !statusOverrides.isEmpty || !removed.isEmpty else { return items }
        return items.compactMap { item in
            if removed.contains(item.id) { return nil }
            guard let status = statusOverrides[item.id] else { return item }
            var copy = item
            copy.status = status
            return copy
        }
    }

    static func perform(_ action: QueueAggregator.Action, on item: QueueItem) {
        switch action {
        case .pause:
            statusOverrides[item.id] = .paused
        case .resume, .continueDownload:
            statusOverrides[item.id] = .downloading
        case .delete:
            removed.insert(item.id)
            statusOverrides.removeValue(forKey: item.id)
        }
    }

    /// Leaving demo wipes the demo profile; these edits have to go with it, or
    /// re-entering shows the previous visit's cancellations.
    static func reset() {
        statusOverrides.removeAll()
        removed.removeAll()
    }
}
