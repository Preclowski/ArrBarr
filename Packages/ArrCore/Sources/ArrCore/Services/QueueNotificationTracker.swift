import Foundation

/// Decides which freshly-observed queue items deserve a notification, with
/// dedup that survives the messy realities of polling an arr queue — including
/// **app relaunches**, which is the case the first in-memory version missed.
///
/// Real-world behaviours that used to produce duplicate banners:
///
///   1. **App relaunch.** The tracker lives for one launch. A menu-bar app is
///      relaunched often (login, wake, rebuilds). An in-memory tracker re-seeds
///      each launch and only silences whatever happens to be in the first
///      successful fetch — so a long-stuck download (an item sitting in the
///      queue for days) re-notified on launches where the first fetch was slow,
///      empty, or errored. Fixed by **persisting** the seen-state across
///      launches (this is the "local cache of sent notifications" the feature
///      was meant to be).
///
///   2. **Transient fetch failure.** `QueueAggregator.safeFetch` returns an
///      *empty* list (plus an error) when an arr times out or restarts. That
///      empty result must not read as "the queue emptied" or every item
///      re-notifies on the next success. The caller folds only the sources
///      whose fetch succeeded.
///
///   3. **Unstable identity / brief drop-out.** The arr re-assigns a queue
///      record id mid-download and items can momentarily leave the queue.
///      Keyed on the stable `downloadId` and accumulating (never shrinking)
///      remembered keys, neither re-notifies.
///
/// **Eviction safety:** remembered keys are FIFO-capped per arr to bound
/// storage, but any key for an item *currently in the queue* is always retained
/// regardless of the cap — so a download stuck for weeks behind thousands of
/// others can never be evicted and re-notified.
///
/// Pure `Codable` value type with no side effects — the view model owns the
/// per-arr notify toggle, banner dispatch, and persistence.
nonisolated struct QueueNotificationTracker: Codable, Equatable {
    /// Per-arr remembered keys, oldest-first. Keyed by `Source.rawValue` so the
    /// dictionary encodes as a plain keyed JSON object. A missing entry means
    /// "this arr has never had a successful fetch" and drives the silent seed.
    private var seen: [String: [String]] = [:]

    /// Upper bound on remembered keys per arr. Generous — months of normal
    /// download volume — and currently-queued items are exempt anyway.
    static let capPerSource = 2000

    /// Pending releases by `handoffKey` → when they left the queue (`distantFuture` while still
    /// pending). Their download arrives under a new identity and is the same event, already announced.
    /// Optional so caches persisted before it existed still decode.
    private var pendingHandoffs: [String: Date]?

    /// How long after a pending row leaves the queue its download may still turn up.
    static let handoffWindow: TimeInterval = 15 * 60

    /// Fold one source's fetched rows into the cache and return the ones worth
    /// announcing.
    ///
    /// Per-source because that is the unit a fetch now covers. Folding a source
    /// the caller has *not* just fetched is not merely wasteful — it is wrong:
    /// the silent first-fetch seed below would record that source's placeholder
    /// (usually empty) as its history, and its real rows would then all look new
    /// the moment they did arrive. Committing four sources one at a time through
    /// the all-sources shape used to do exactly that on a fresh cache, turning a
    /// first launch with a busy queue into one banner per queued item.
    mutating func newItems(for source: QueueItem.Source, items: [QueueItem], now: Date = Date()) -> [QueueItem] {
        let raw = source.rawValue
        let currentKeys = items.map(Self.key(for:))
        var handoffs = Self.foldHandoffs(pendingHandoffs ?? [:], source: source, items: items, now: now)
        defer { pendingHandoffs = handoffs.isEmpty ? nil : handoffs }

        guard let history = seen[raw] else {
            // First successful fetch for this arr: remember what's already
            // queued without announcing it — those items predate the cache.
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

    /// Stamps this source's pending rows as present, starts the clock on the ones that just left,
    /// and drops the ones whose download never turned up.
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

    /// Builds the next remembered list: every currently-queued key is retained
    /// (so a long-stuck download is NEVER evicted and can't re-notify), plus the
    /// most-recent historical keys filling the remaining cap budget. Current
    /// keys sort last (newest); aged-out historical keys drop off the front.
    private static func merged(current: [String], history: [String]) -> [String] {
        var seenSet = Set<String>()
        let currentUnique = current.filter { seenSet.insert($0).inserted }
        let currentSet = Set(currentUnique)
        let historical = history.filter { !currentSet.contains($0) }
        let budget = max(0, capPerSource - currentUnique.count)
        return Array(historical.suffix(budget)) + currentUnique
    }

    /// Stable per-item identity for dedup. Prefers the download-client hash
    /// (`downloadId`) — unlike the queue record id baked into `item.id`, it
    /// survives the arr re-assigning a record id mid-download. Season packs
    /// share one `downloadId` across episodes, so the season/episode pair is
    /// appended to keep each episode its own banner. Falls back to `item.id`
    /// only when no `downloadId` is present.
    static func key(for item: QueueItem) -> String {
        let base = (item.downloadId?.isEmpty == false) ? item.downloadId! : item.id
        let ep = item.seasonNumber.map { "|S\($0)E\(item.episodeNumber ?? -1)" } ?? ""
        return "\(item.source.rawValue)|\(base)\(ep)"
    }
}
