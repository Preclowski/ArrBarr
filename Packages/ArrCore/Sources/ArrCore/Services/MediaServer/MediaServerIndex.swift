import Foundation
import MediaKit
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
nonisolated public final class MediaServerIndex: @unchecked Sendable {
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

    /// How many plays the refresh actually asks for. Bigger than the Quiz's
    /// slice because the tail is what marks individual episodes as watched,
    /// and a week of TV is a lot of rows — the Quiz still sees only the
    /// newest `watchHistoryLimit`.
    private static let watchHistoryFetchLimit = 300

    /// One built index. Held by a MediaKit `Snapshot` over the store's library and history tags, so the
    /// first build of a launch comes off the persisted rows and every later commit rebuilds it.
    nonisolated struct State: Sendable {
        var byKey: [MediaServerExternalKey: MediaServerEntry] = [:]
        var watchHistory: [MediaServerWatch] = []
        /// Episodes the server has played, per series item id. A series is only
        /// ever "watched" as a whole once every episode is, which is never true of
        /// a show that is still airing — so the per-episode answer is the only one
        /// an Upcoming row can use. Built from the same history call, so it costs
        /// no extra request and reaches back as far as `watchHistoryFetchLimit`.
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

    /// How often a stale snapshot may ask again while the server keeps failing; each attempt re-decodes the stored index.
    private static let retryAfter: TimeInterval = 60

    private let lock = NSLock()
    private var live: Live?
    /// A snapshot being built for a config; poster downloads wait on it rather than go out without a token.
    private var pending: (config: MediaServerConfig, task: Task<Live?, Never>)?
    private var lastAttempt: Date?
    /// Hash of the key → poster map last announced, so a rebuild that changes no artwork does not recompose the queue.
    private var announcedPosters: Int?
    /// Season posters per series item id, fetched lazily when a season screen
    /// opens rather than during the library sweep — one extra request per
    /// series the user actually looks at, instead of one per series on the
    /// server. `[:]` for a series means "asked, the server has none".
    private var seasonPostersByItem: [String: [Int: ArtworkReference]] = [:]
    /// Item ids with a season-poster fetch in flight, so a season screen that
    /// is opened, popped and reopened doesn't issue the request twice.
    private var seasonFetchesInFlight: Set<String> = []

    private static let log = Logger(category: "MediaServer")

    init() {}

    private var state: State { lock.withLock { live?.snapshot.current.value } ?? State() }

    // MARK: - Reads (synchronous, hot path)

    /// The media server's poster for a title, or nil to keep the arr's.
    public func posterURL(for keys: [MediaServerExternalKey]) -> URL? {
        entry(for: keys)?.posterURL
    }

    /// One episode's coordinates within its series.
    public struct SeasonEpisode: Hashable, Sendable {
        public let season: Int
        public let episode: Int
        public init(season: Int, episode: Int) {
            self.season = season
            self.episode = episode
        }
    }

    /// Whether the server has played this particular episode. Falls back to
    /// the title-level answer when the row carries no episode coordinates
    /// (a movie, or a series row).
    public func isWatched(_ keys: [MediaServerExternalKey], season: Int?, episode: Int?) -> Bool {
        guard let season, let episode else { return isWatched(keys) }
        let state = state
        guard let itemId = Self.entry(for: keys, in: state)?.itemId else { return false }
        return state.watchedEpisodesBySeries[itemId]?.contains(SeasonEpisode(season: season, episode: episode)) ?? false
    }

    /// Whether the server has this title marked watched. Unknown titles are
    /// reported as not watched — the Quiz must not hide something just because
    /// the index hasn't loaded.
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

    /// The media server's poster for one season of a title, or nil when it has
    /// none (or hasn't been asked yet — call `loadSeasonPosters` first).
    public func seasonPosterURL(for keys: [MediaServerExternalKey], season: Int) -> URL? {
        guard let itemId = entry(for: keys)?.itemId else { return nil }
        return lock.withLock { seasonPostersByItem[itemId]?[season]?.url }
    }

    /// The artwork reference behind a media-server poster URL this index handed out, so `PosterStore` can size it
    /// and resolve its credential. Waits for the snapshot's first build rather than answer nil at launch.
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

    /// Recently watched titles, newest first. Used as the Quiz's taste signal.
    public func recentlyWatched() -> [MediaServerWatch] {
        Array(state.watchHistory.prefix(Self.watchHistoryLimit))
    }

    /// Distinct titles in the snapshot. Counted over entries rather than keys —
    /// a title with both a tmdb and an imdb id occupies two keys and is still
    /// one title, which is the number Settings should show.
    public var indexedTitleCount: Int {
        Set(state.byKey.values.map(\.itemId)).count
    }

    public var lastRefreshedAt: Date? { state.fetchedAt }

    // MARK: - Writes

    /// Rebuild when the snapshot is missing, older than `staleAfter`, or was
    /// built from a different config. Safe to call on every queue poll — in the
    /// common case it is a lock and a date comparison.
    public func refreshIfStale(config: MediaServerConfig) async {
        guard config.isConfigured else {
            // Feature switched off or half-configured: drop whatever we hold so
            // the app stops showing a disconnected server's artwork.
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

    /// Ask the server now (Settings' reindex and a passed connection test). A
    /// failure leaves the previous snapshot in place — a server that goes away
    /// mid-evening must not blank every poster in the UI.
    public func refresh(config: MediaServerConfig) async {
        guard config.isConfigured, let live = await resolveLive(for: config)?.live else { return }
        await live.store.invalidate(Self.tags(live.instance), reason: .manual)
        await live.snapshot.start()
    }

    /// The snapshot for this config on the current gateway's store; `built` when this call (or one it joined) just
    /// built it, so the caller does not rebuild it a second time.
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

    /// Queue rows resolve their poster when composed; the first launch composes before this index is built.
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

    /// The stored rows first; the store revalidates behind them and its commit rebuilds the snapshot.
    private static func state(_ facade: MediaServerFacade) async -> State {
        guard let index = try? await facade.libraryIndex(policy: .staleWhileRevalidate) else {
            log.debug("Media server index has no library rows yet")
            return State()
        }
        // Watch history is a second, much smaller call, and a server that
        // answers the library but not the history should still get posters.
        let history = (try? await facade.recentlyWatched(limit: watchHistoryFetchLimit, policy: .staleWhileRevalidate)) ?? []

        var state = State(watchHistory: history, fetchedAt: index.fetchedAt)
        state.byKey.reserveCapacity(index.entries.count * 2)
        for entry in index.entries {
            if let poster = entry.poster { state.artworkByURL[poster.url] = poster }
            for key in entry.externalKeys {
                // First writer wins. Two library items claiming the same
                // tmdb id means a duplicate on the server; picking one
                // deterministically beats letting scan order decide which
                // poster the UI shows on each refresh.
                if state.byKey[key] == nil { state.byKey[key] = entry }
            }
        }
        for play in history {
            guard let series = play.seriesItemId, let season = play.season, let episode = play.episode else { continue }
            state.watchedEpisodesBySeries[series, default: []].insert(SeasonEpisode(season: season, episode: episode))
        }
        // Rebuilt on every commit — `.debug`, same as every other repeating pass.
        log.debug("Media server index built: \(index.entries.count, privacy: .public) titles, \(history.count, privacy: .public) recent plays")
        return state
    }

    /// Fetch this series' season artwork, once. A miss, a failure or a server
    /// that doesn't know the title all leave the cache empty and every reader
    /// falls back to the arr's poster — same contract as the rest of this type.
    /// Runs against the config the current snapshot was built from — the one
    /// that produced the item id being asked about. Nothing to load before the
    /// first refresh, which is also when `entry(for:)` has no answer anyway.
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

    /// Drop the snapshot. Used when the user disables the integration so the
    /// change is visible immediately instead of at the next poll.
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
