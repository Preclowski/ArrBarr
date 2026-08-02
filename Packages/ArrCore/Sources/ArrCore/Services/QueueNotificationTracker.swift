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
///      re-notifies on the next success. The caller passes `errored` so those
///      arrs are skipped entirely.
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
struct QueueNotificationTracker: Codable, Equatable {
    /// Per-arr remembered keys, oldest-first. Keyed by `Source.rawValue` so the
    /// dictionary encodes as a plain keyed JSON object. A missing entry means
    /// "this arr has never had a successful fetch" and drives the silent seed.
    private var seen: [String: [String]] = [:]

    /// Upper bound on remembered keys per arr. Generous — months of normal
    /// download volume — and currently-queued items are exempt anyway.
    static let capPerSource = 2000

    /// Returns the items that should fire a notification this cycle and folds
    /// the successful snapshots into internal state.
    ///
    /// - Parameters:
    ///   - perSource: the latest queue snapshot per arr.
    ///   - errored: arrs whose fetch failed this cycle. Their snapshot is
    ///     ignored — an empty list from a failed fetch is not evidence the
    ///     queue is empty.
    mutating func newItems(
        perSource: [QueueItem.Source: [QueueItem]],
        errored: Set<QueueItem.Source>
    ) -> [QueueItem] {
        var result: [QueueItem] = []
        for source in QueueItem.Source.allCases where !errored.contains(source) {
            result += newItems(for: source, items: perSource[source] ?? [])
        }
        return result
    }

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
    mutating func newItems(for source: QueueItem.Source, items: [QueueItem]) -> [QueueItem] {
        let raw = source.rawValue
        let currentKeys = items.map(Self.key(for:))

        guard let history = seen[raw] else {
            // First successful fetch for this arr: remember what's already
            // queued without announcing it — those items predate the cache.
            seen[raw] = Self.merged(current: currentKeys, history: [])
            return []
        }

        let known = Set(history)
        let fresh = items.filter { !known.contains(Self.key(for: $0)) }
        seen[raw] = Self.merged(current: currentKeys, history: history)
        return fresh
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
