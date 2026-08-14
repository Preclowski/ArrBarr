import Foundation
import os

/// Everything the media server knows about the library, in one snapshot that
/// the rest of the app can read **synchronously**.
///
/// Synchronous reads are the whole design constraint. Poster URLs are resolved
/// deep inside the arr clients and view models — a dozen non-async call sites
/// that turn a `[ArrImage]` array into a URL — and an actor would push `await`
/// into every one of them (and into `Array.posterURL(baseURL:)`, which is a
/// pure function today). So this is a lock-guarded snapshot instead: writes
/// happen once per refresh on a background task, reads are a dictionary lookup
/// behind an uncontended lock.
///
/// A missing or stale index is never an error. Every reader falls back to the
/// arr's own artwork, which is exactly what the app did before this existed.
public final class MediaServerIndex: @unchecked Sendable {
    public static let shared = MediaServerIndex()

    /// How long a snapshot is trusted before `refreshIfStale` re-fetches.
    /// A library's artwork and watch state move on the scale of an evening,
    /// not seconds, and the fetch walks every item on the server — so this is
    /// deliberately far slower than the queue's polling loop, which is what
    /// drives it.
    private static let staleAfter: TimeInterval = 15 * 60

    /// How many recently-watched titles the Quiz prompt is allowed to carry.
    /// Enough to characterise taste, small enough not to dominate the prompt.
    public static let watchHistoryLimit = 40

    private let lock = NSLock()
    private var byKey: [MediaServerExternalKey: MediaServerEntry] = [:]
    private var watchHistory: [MediaServerWatch] = []
    private var lastRefresh: Date?
    private var isRefreshing = false
    /// Config the current snapshot was built from. A change to the server,
    /// URL or token invalidates it immediately rather than at the next stale
    /// check — otherwise switching servers leaves the old one's posters up for
    /// a quarter of an hour.
    private var snapshotConfig: MediaServerConfig?

    private let logger = Logger(category: "MediaServer")

    init() {}

    // MARK: - Reads (synchronous, hot path)

    /// The media server's poster for a title, or nil to keep the arr's.
    public func posterURL(for keys: [MediaServerExternalKey]) -> URL? {
        entry(for: keys)?.posterURL
    }

    /// Whether the server has this title marked watched. Unknown titles are
    /// reported as not watched — the Quiz must not hide something just because
    /// the index hasn't loaded.
    public func isWatched(_ keys: [MediaServerExternalKey]) -> Bool {
        entry(for: keys)?.watched ?? false
    }

    public func entry(for keys: [MediaServerExternalKey]) -> MediaServerEntry? {
        guard !keys.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        for key in keys {
            if let hit = byKey[key] { return hit }
        }
        return nil
    }

    /// Recently watched titles, newest first. Used as the Quiz's taste signal.
    public func recentlyWatched() -> [MediaServerWatch] {
        lock.lock()
        defer { lock.unlock() }
        return watchHistory
    }

    /// Distinct titles in the snapshot. Counted over entries rather than keys —
    /// a title with both a tmdb and an imdb id occupies two keys and is still
    /// one title, which is the number Settings should show.
    public var indexedTitleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Set(byKey.values.map(\.itemId)).count
    }

    public var lastRefreshedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastRefresh
    }

    // MARK: - Writes

    /// Refresh when the snapshot is missing, stale, or was built from a
    /// different config. Safe to call on every queue poll — it is a lock and a
    /// date comparison in the common case.
    public func refreshIfStale(config: MediaServerConfig) async {
        guard shouldRefresh(config: config) else { return }
        await refresh(config: config)
    }

    private func shouldRefresh(config: MediaServerConfig) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isRefreshing else { return false }
        guard config.isConfigured else {
            // Feature switched off or half-configured: drop whatever we hold so
            // the app stops showing a disconnected server's artwork.
            reset()
            return false
        }
        if snapshotConfig != config { return true }
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) > Self.staleAfter
    }

    /// Fetch a fresh snapshot. A failure leaves the previous one in place — a
    /// server that goes away mid-evening must not blank every poster in the UI.
    public func refresh(config: MediaServerConfig) async {
        guard let client = MediaServerClientFactory.make(config: config) else { return }
        lock.lock(); isRefreshing = true; lock.unlock()
        defer { lock.lock(); isRefreshing = false; lock.unlock() }

        do {
            let entries = try await client.libraryIndex()
            // Watch history is a second, much smaller call, and a server that
            // answers the library but not the history should still get posters.
            let history = (try? await client.recentlyWatched(limit: Self.watchHistoryLimit)) ?? []

            var map: [MediaServerExternalKey: MediaServerEntry] = [:]
            map.reserveCapacity(entries.count * 2)
            for entry in entries {
                for key in entry.externalKeys {
                    // First writer wins. Two library items claiming the same
                    // tmdb id means a duplicate on the server; picking one
                    // deterministically beats letting scan order decide which
                    // poster the UI shows on each refresh.
                    if map[key] == nil { map[key] = entry }
                }
            }

            lock.lock()
            byKey = map
            watchHistory = history
            snapshotConfig = config
            lastRefresh = Date()
            lock.unlock()

            logger.info("Media server index refreshed: \(entries.count, privacy: .public) titles, \(history.count, privacy: .public) recent plays")
        } catch {
            logger.error("Media server index refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drop the snapshot. Used when the user disables the integration so the
    /// change is visible immediately instead of at the next poll.
    public func clear() {
        lock.lock()
        reset()
        lock.unlock()
    }

    /// Caller must hold `lock`.
    private func reset() {
        byKey.removeAll()
        watchHistory.removeAll()
        snapshotConfig = nil
        lastRefresh = nil
    }
}
