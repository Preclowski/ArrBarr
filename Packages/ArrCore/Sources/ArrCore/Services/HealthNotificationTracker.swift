import Foundation

/// Remembers which arr health problems have already been announced.
///
/// Health is polled on a slow clock and a broken indexer stays broken, so the
/// same records come back every cycle. Without this, "Sonarr: indexer
/// unavailable" would fire a banner every fifteen minutes until someone fixed
/// it — the fastest way to teach a user to ignore the app's notifications.
///
/// Persisted for the same reason `QueueNotificationTracker` is: an app that
/// gets relaunched (or, on this app's history, terminated by the OS) would
/// otherwise re-announce every standing problem on every launch.
///
/// Resolution matters as much as onset: a record that stops being reported is
/// forgotten, so if the same problem recurs later it is announced again. That
/// is the difference between "we told you once, ever" and "we tell you when it
/// happens".
struct HealthNotificationTracker: Codable, Equatable {
    /// Keys of the records announced so far, per source.
    private var announced: [String: Set<String>] = [:]

    /// Identity of one problem. Message is part of it because Servarr reuses a
    /// `type` across unrelated failures — two different broken indexers are both
    /// `warning`, and collapsing them would announce only the first.
    static func key(_ record: ArrHealthRecord) -> String {
        "\(record.type ?? "")|\(record.message ?? "")"
    }

    /// Fold this source's current records in, returning the ones not yet
    /// announced. Records that have disappeared are dropped from the cache.
    mutating func newIssues(
        for source: QueueItem.Source, records: [ArrHealthRecord]
    ) -> [ArrHealthRecord] {
        let raw = source.rawValue
        let currentKeys = Set(records.map(Self.key))
        let known = announced[raw] ?? []
        announced[raw] = currentKeys
        return records.filter { !known.contains(Self.key($0)) }
    }
}
