import Foundation

/// Persisted notification dedup: keyed on the stable `downloadId`, remembered keys only
/// accumulate, and currently-queued keys are never evicted by the per-arr cap.
nonisolated struct QueueNotificationTracker: Codable, Equatable {
    /// Keyed by `Source.rawValue`; a missing entry means no successful fetch yet and drives the silent seed.
    private var seen: [String: [String]] = [:]

    /// Months of normal download volume; currently-queued items are exempt anyway.
    static let capPerSource = 2000

    /// `handoffKey` → when the pending row left the queue (`distantFuture` while pending); its download
    /// arrives under a new identity but was already announced. Optional so older caches decode.
    private var pendingHandoffs: [String: Date]?

    static let handoffWindow: TimeInterval = 15 * 60

    /// Only fold a source the caller just fetched: the silent seed would record its
    /// placeholder as history and every real row would then look new.
    mutating func newItems(for source: QueueItem.Source, items: [QueueItem], now: Date = Date()) -> [QueueItem] {
        let raw = source.rawValue
        let currentKeys = items.map(Self.key(for:))
        var handoffs = Self.foldHandoffs(pendingHandoffs ?? [:], source: source, items: items, now: now)
        defer { pendingHandoffs = handoffs.isEmpty ? nil : handoffs }

        guard let history = seen[raw] else {
            // First successful fetch: remember what's queued without announcing it.
            seen[raw] = Self.merged(current: currentKeys, history: [])
            return []
        }

        let known = Set(history)
        let fresh = items.filter { item in
            guard !known.contains(Self.key(for: item)) else { return false }
            guard !item.isPendingRelease, let handoff = item.handoffKey, handoffs[handoff] != nil else { return true }
            handoffs[handoff] = nil
            return false
        }
        seen[raw] = Self.merged(current: currentKeys, history: history)
        return fresh
    }

    private static func foldHandoffs(_ handoffs: [String: Date], source: QueueItem.Source, items: [QueueItem], now: Date) -> [String: Date] {
        let present = Set(items.filter(\.isPendingRelease).compactMap(\.handoffKey))
        var out: [String: Date] = [:]
        for (key, leftAt) in handoffs {
            guard key.hasPrefix("\(source.rawValue)|"), !present.contains(key) else { out[key] = leftAt; continue }
            let stamped = leftAt == .distantFuture ? now : leftAt
            if now.timeIntervalSince(stamped) < handoffWindow { out[key] = stamped }
        }
        for key in present { out[key] = .distantFuture }
        return out
    }

    /// Current keys always kept and sorted newest; history fills the rest of the cap.
    private static func merged(current: [String], history: [String]) -> [String] {
        var seenSet = Set<String>()
        let currentUnique = current.filter { seenSet.insert($0).inserted }
        let currentSet = Set(currentUnique)
        let historical = history.filter { !currentSet.contains($0) }
        let budget = max(0, capPerSource - currentUnique.count)
        return Array(historical.suffix(budget)) + currentUnique
    }

    /// `downloadId` survives the arr re-assigning a record id; season packs share one,
    /// so season/episode is appended. Falls back to `item.id`.
    static func key(for item: QueueItem) -> String {
        let base = (item.downloadId?.isEmpty == false) ? item.downloadId! : item.id
        let ep = item.seasonNumber.map { "|S\($0)E\(item.episodeNumber ?? -1)" } ?? ""
        return "\(item.source.rawValue)|\(base)\(ep)"
    }
}
