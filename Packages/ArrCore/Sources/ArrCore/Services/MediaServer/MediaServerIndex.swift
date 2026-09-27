import Foundation
import MediaKit
import os

/// A lock-guarded snapshot, not an actor: poster URLs resolve in a dozen synchronous
/// call sites. A missing or stale index is never an error; readers fall back to the arr's artwork.
nonisolated public final class MediaServerIndex: @unchecked Sendable {
    public static let shared = MediaServerIndex()

    /// Artwork and watch state move on the scale of an evening, and the fetch walks every item.
    private static let staleAfter: TimeInterval = 15 * 60

    /// Enough to characterise taste, small enough not to dominate the Quiz prompt.
    public static let watchHistoryLimit = 40

    /// Bigger than the Quiz's slice: the tail marks individual episodes watched.
    private static let watchHistoryFetchLimit = 300

    /// Held by a MediaKit `Snapshot`, so a launch's first build comes off the persisted rows.
    nonisolated struct State: Sendable {
        var byKey: [MediaServerExternalKey: MediaServerEntry] = [:]
        var watchHistory: [MediaServerWatch] = []
        /// A still-airing series is never watched as a whole, so Upcoming rows need the
        /// per-episode answer. Built from the same history call.
        var watchedEpisodesBySeries: [String: Set<SeasonEpisode>] = [:]
        var artworkByURL: [URL: ArtworkReference] = [:]
        /// When the server last answered the library read (not when this was built).
        var fetchedAt: Date?
    }

    nonisolated private struct Live {
        let config: MediaServerConfig
        let store: ResourceStore
        let instance: InstanceID
        let snapshot: Snapshot<State>
    }

    /// Throttles retries while the server keeps failing; each attempt re-decodes the stored index.
    private static let retryAfter: TimeInterval = 60

    private let lock = NSLock()
    private var live: Live?
    /// Poster downloads wait on this rather than go out without a token.
    private var pending: (config: MediaServerConfig, task: Task<Live?, Never>)?
    private var lastAttempt: Date?
    /// So a rebuild that changes no artwork does not recompose the queue.
    private var announcedPosters: Int?
    /// Fetched lazily per series the user opens, not during the sweep. `[:]` = asked, none.
    private var seasonPostersByItem: [String: [Int: ArtworkReference]] = [:]
    private var seasonFetchesInFlight: Set<String> = []

    private static let log = Logger(category: "MediaServer")

    init() {}

    private var state: State { lock.withLock { live?.snapshot.current.value } ?? State() }

    // MARK: - Reads (synchronous, hot path)

    public func posterURL(for keys: [MediaServerExternalKey]) -> URL? {
        entry(for: keys)?.posterURL
    }

    public struct SeasonEpisode: Hashable, Sendable {
        public let season: Int
        public let episode: Int
        public init(season: Int, episode: Int) {
            self.season = season
            self.episode = episode
        }
    }

    /// Falls back to the title-level answer when the row has no episode coordinates.
    public func isWatched(_ keys: [MediaServerExternalKey], season: Int?, episode: Int?) -> Bool {
        guard let season, let episode else { return isWatched(keys) }
        let state = state
        guard let itemId = Self.entry(for: keys, in: state)?.itemId else { return false }
        return state.watchedEpisodesBySeries[itemId]?.contains(SeasonEpisode(season: season, episode: episode)) ?? false
    }

    /// Unknown titles report not watched: the Quiz must not hide something because the index hasn't loaded.
    public func isWatched(_ keys: [MediaServerExternalKey]) -> Bool {
        entry(for: keys)?.watched ?? false
    }

    public func entry(for keys: [MediaServerExternalKey]) -> MediaServerEntry? {
        guard !keys.isEmpty else { return nil }
        return Self.entry(for: keys, in: state)
    }

    private static func entry(for keys: [MediaServerExternalKey], in state: State) -> MediaServerEntry? {
        for key in keys {
            if let hit = state.byKey[key] { return hit }
        }
        return nil
    }

    /// nil when the server has none or it hasn't been asked (`loadSeasonPosters`).
    public func seasonPosterURL(for keys: [MediaServerExternalKey], season: Int) -> URL? {
        guard let itemId = entry(for: keys)?.itemId else { return nil }
        return lock.withLock { seasonPostersByItem[itemId]?[season]?.url }
    }

    /// Waits for the snapshot's first build rather than answer nil at launch.
    public func artwork(for url: URL) async -> ArtworkReference? {
        if let hit = artworkNow(for: url) { return hit }
        let task = lock.withLock { () -> Task<Live?, Never>? in
            guard let pending, URL(string: pending.config.baseURL)?.host == url.host else { return nil }
            return pending.task
        }
        guard let task else { return nil }
        _ = await task.value
        return artworkNow(for: url)
    }

    private func artworkNow(for url: URL) -> ArtworkReference? {
        if let hit = state.artworkByURL[url] { return hit }
        return lock.withLock { seasonPostersByItem.values.lazy.flatMap(\.values).first { $0.url == url } }
    }

    public func recentlyWatched() -> [MediaServerWatch] {
        Array(state.watchHistory.prefix(Self.watchHistoryLimit))
    }

    /// Counted over entries: a title with both tmdb and imdb ids occupies two keys.
    public var indexedTitleCount: Int {
        Set(state.byKey.values.map(\.itemId)).count
    }

    public var lastRefreshedAt: Date? { state.fetchedAt }

    // MARK: - Writes

    /// Safe on every queue poll: usually just a lock and a date comparison.
    public func refreshIfStale(config: MediaServerConfig) async {
        guard config.isConfigured else {
            // Stop showing a disconnected server's artwork.
            clear()
            return
        }
        guard let resolved = await resolveLive(for: config), !resolved.built else { return }
        let live = resolved.live
        let now = Date()
        let due = lock.withLock { () -> Bool in
            if let fetchedAt = live.snapshot.current.value.fetchedAt, now.timeIntervalSince(fetchedAt) <= Self.staleAfter { return false }
            if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retryAfter { return false }
            lastAttempt = now
            return true
        }
        if due { await live.snapshot.start() }
    }

    /// A failure keeps the previous snapshot: a server going away must not blank every poster.
    public func refresh(config: MediaServerConfig) async {
        guard config.isConfigured, let live = await resolveLive(for: config)?.live else { return }
        await live.store.invalidate(Self.tags(live.instance), reason: .manual)
        await live.snapshot.start()
    }

    /// `built` when this call (or one it joined) just built it, so the caller doesn't rebuild.
    private func resolveLive(for config: MediaServerConfig) async -> (live: Live, built: Bool)? {
        let store = await ServiceGateway.resolve().store
        let task: Task<Live?, Never>? = lock.withLock {
            if let live, live.config == config, live.store === store { return nil }
            if let pending, pending.config == config { return pending.task }
            let task = Task { await self.build(config) }
            pending = (config, task)
            return task
        }
        guard let task else { return lock.withLock { live }.map { ($0, false) } }
        return await task.value.map { ($0, true) }
    }

    private func build(_ config: MediaServerConfig) async -> Live? {
        let facade = MediaServerFacade(config: config)
        guard let scope = try? await facade.scope() else {
            lock.withLock { if pending?.config == config { pending = nil } }
            return nil
        }
        let snapshot = Snapshot(tags: Self.tags(scope.instance), initial: State(), store: scope.store, settle: .milliseconds(500),
                                didRebuild: { [weak self] in self?.announceIfPostersChanged($0) }) { _ in
            await Self.state(facade)
        }
        await snapshot.start()
        let live = Live(config: config, store: scope.store, instance: scope.instance, snapshot: snapshot)
        // A `clear()` or another config that arrived meanwhile wins; this one is dropped.
        let (installed, previous) = lock.withLock { () -> (Bool, Snapshot<State>?) in
            guard pending?.config == config else { return (false, nil) }
            let previous = self.live?.snapshot
            self.live = live
            pending = nil
            lastAttempt = Date()
            seasonPostersByItem.removeAll()
            return (true, previous)
        }
        previous?.stop()
        guard installed else {
            snapshot.stop()
            return nil
        }
        // The first value landed before `live` was installed, so its announcement was skipped.
        announceIfPostersChanged(snapshot.current.value)
        return live
    }

    /// The first launch composes queue rows before this index is built.
    private func announceIfPostersChanged(_ state: State) {
        let signature = state.byKey.compactMapValues(\.posterURL).hashValue
        let changed = lock.withLock { () -> Bool in
            guard live != nil, announcedPosters != signature else { return false }
            announcedPosters = signature
            return true
        }
        guard changed else { return }
        Self.log.notice("Media server artwork changed: \(state.byKey.count, privacy: .public) keys, recomposing the queue")
        AppMessages.post(AppMessages.MediaServerArtworkChanged())
    }

    private static func tags(_ instance: InstanceID) -> Set<InvalidationTag> {
        [.collection(.library, instance), .collection(.history, instance)]
    }

    private static func state(_ facade: MediaServerFacade) async -> State {
        guard let index = try? await facade.libraryIndex(policy: .staleWhileRevalidate) else {
            log.debug("Media server index has no library rows yet")
            return State()
        }
        // A server that answers the library but not the history should still get posters.
        let history = (try? await facade.recentlyWatched(limit: watchHistoryFetchLimit, policy: .staleWhileRevalidate)) ?? []

        var state = State(watchHistory: history, fetchedAt: index.fetchedAt)
        state.byKey.reserveCapacity(index.entries.count * 2)
        for entry in index.entries {
            if let poster = entry.poster { state.artworkByURL[poster.url] = poster }
            for key in entry.externalKeys {
                // First writer wins: a duplicate tmdb id must not let scan order pick the poster.
                if state.byKey[key] == nil { state.byKey[key] = entry }
            }
        }
        for play in history {
            guard let series = play.seriesItemId, let season = play.season, let episode = play.episode else { continue }
            state.watchedEpisodesBySeries[series, default: []].insert(SeasonEpisode(season: season, episode: episode))
        }
        log.debug("Media server index built: \(index.entries.count, privacy: .public) titles, \(history.count, privacy: .public) recent plays")
        return state
    }

    /// Any miss leaves the cache empty and readers fall back to the arr's poster.
    /// Uses the config the current snapshot was built from, which produced the item id.
    public func loadSeasonPosters(for keys: [MediaServerExternalKey]) async {
        guard let itemId = entry(for: keys)?.itemId else { return }
        let config = lock.withLock { live?.config }
        guard let config, config.isConfigured else { return }

        let known = lock.withLock {
            let known = seasonPostersByItem[itemId] != nil || seasonFetchesInFlight.contains(itemId)
            if !known { seasonFetchesInFlight.insert(itemId) }
            return known
        }
        guard !known else { return }

        defer { lock.withLock { _ = seasonFetchesInFlight.remove(itemId) } }
        do {
            let posters = try await MediaServerFacade(config: config).seasonPosters(seriesItemId: itemId)
            lock.withLock { seasonPostersByItem[itemId] = posters }
            Self.log.debug("Season posters for item \(itemId, privacy: .public): \(posters.count, privacy: .public)")
        } catch {
            Self.log.error(
                "Season poster fetch failed: \(error.localizedDescription, privacy: .public) | \(String(reflecting: error), privacy: .private)"
            )
        }
    }

    public func clear() {
        let previous = lock.withLock { () -> Snapshot<State>? in
            let previous = live?.snapshot
            live = nil
            pending = nil
            lastAttempt = nil
            announcedPosters = nil
            seasonPostersByItem.removeAll()
            return previous
        }
        previous?.stop()
    }
}
