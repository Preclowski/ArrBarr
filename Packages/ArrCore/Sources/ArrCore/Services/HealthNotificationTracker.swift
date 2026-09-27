import Foundation
import MediaKit

/// Announces each arr health problem once while it persists, again if it recurs.
/// Persisted so relaunches don't re-announce standing problems.
nonisolated struct HealthNotificationTracker: Codable, Equatable {
    private var announced: [String: Set<String>] = [:]

    /// Includes the message: Servarr reuses a `type` across unrelated failures.
    static func key(_ record: ArrHealth) -> String {
        "\(record.type ?? "")|\(record.message ?? "")"
    }

    /// Records that disappeared are forgotten, so a recurrence is announced again.
    mutating func newIssues(
        for source: QueueItem.Source, records: [ArrHealth]
    ) -> [ArrHealth] {
        let raw = source.rawValue
        let currentKeys = Set(records.map(Self.key))
        let known = announced[raw] ?? []
        announced[raw] = currentKeys
        return records.filter { !known.contains(Self.key($0)) }
    }
}
