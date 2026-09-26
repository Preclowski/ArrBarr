import Foundation
import os

/// One cached copy of the Radarr / Sonarr / Lidarr / Whisparr libraries,
/// shared by every tool that needs to know what the user owns.
///
/// Before this, each tool fetched the whole library itself: `radarr_get_movies`
/// fetched it, and so did the ownership cross-reference behind `suggest_titles`,
/// `discover_in_quiz` and every TMDB tool (`ArrLibraryMaps`). One chat turn that
/// looked up a person, suggested titles and checked the library pulled a
/// 3000-movie payload three times over.
///
/// The refresh rule is deliberately two lines: serve from the snapshot, refetch
/// when it is older than `ttl` **or** when an import invalidated it. The queue
/// already learns about imports over SignalR (`RealtimeEvent.fileImported`), so
/// the case that actually matters — "I just grabbed it, do I have it?" — is
/// answered by an event rather than by guessing a short TTL. Everything else
/// (a monitored toggle in the arr's own UI) can wait for the next `ttl`.
public actor LibraryIndex {

    nonisolated public static let shared = LibraryIndex()

    /// Backstop for changes no event tells us about. Long on purpose: this is
    /// the heaviest call the app makes, and events cover the urgent cases.
    nonisolated public static let ttl: TimeInterval = 10 * 60

    private struct Slot<Record: Sendable>: Sendable {
        var records: [Record]
        var fetchedAt: Date
        /// The config the snapshot was built from — a changed URL or key
        /// invalidates it immediately rather than at the next `ttl`.
        var fingerprint: String
    }

    private var movieSlot: Slot<RadarrLibraryRecord>?
    private var seriesSlot: Slot<SonarrLibraryRecord>?
    private var artistSlot: Slot<LidarrLibraryRecord>?
    private var whisparrSlot: Slot<WhisparrLibraryRecord>?
    /// One in-flight fetch per source. Without it, three tools called in the
    /// same turn each start their own fetch of a cold cache.
    ///
    /// The fingerprint rides along because joining is only safe for the SAME
    /// config: a caller whose server changed mid-fetch would otherwise adopt
    /// the old server's records and `commit` them under the new fingerprint,
    /// where they'd read as fresh for a whole `ttl`.
    ///
    /// `revalidate` rides along for the same reason: a caller that asked the arr
    /// must not adopt the answer of a fetch that only read the disk cache.
    private var movieFetch: (fingerprint: String, revalidate: Bool, task: Task<[RadarrLibraryRecord]?, Never>)?
    private var seriesFetch: (fingerprint: String, revalidate: Bool, task: Task<[SonarrLibraryRecord]?, Never>)?
    private var artistFetch: (fingerprint: String, revalidate: Bool, task: Task<[LidarrLibraryRecord]?, Never>)?
    private var whisparrFetch: (fingerprint: String, revalidate: Bool, task: Task<[WhisparrLibraryRecord]?, Never>)?

    /// Monotonic per-source counter, bumped on every fresh commit and every
    /// invalidate. `LibraryViewModel` unifies against it: same version means
    /// the records behind it are the same objects, so re-unifying a 3000-title
    /// library would be pure waste.
    private var versions: [QueueItem.Source: Int] = [:]
    /// True when the LAST fetch for a source threw. The reads return `[]` (or
    /// a stale snapshot) either way, so this is the only thing that can tell
    /// "the arr is unreachable" from "the library is genuinely empty" — the
    /// Library tab's error state depends on the difference.
    private var failedSources: Set<QueueItem.Source> = []
    /// Sources whose last commit came off the on-disk store rather than the
    /// arr. The Library paints that answer and then asks again — but only when
    /// this says the answer was old; a read that already went to the network
    /// must not be repeated.
    private var servedStale: Set<QueueItem.Source> = []
    private static let log = Logger(category: "LibraryIndex")

    init() {}

    // MARK: - Versions

    public func version(for source: QueueItem.Source) -> Int { versions[source] ?? 0 }

    public func fetchFailed(_ source: QueueItem.Source) -> Bool {
        failedSources.contains(source)
    }

    /// See `servedStale`.
    public func servedStaleSnapshot(_ source: QueueItem.Source) -> Bool {
        servedStale.contains(source)
    }

    // MARK: - Reads

    public func movies(config: ServiceConfig, revalidate: Bool = true) async -> [RadarrLibraryRecord] {
        guard config.isConfigured else { return [] }
        let fingerprint = config.identityFingerprint
        if let slot = movieSlot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            Self.log.notice("radarr records: in-memory snapshot")
            return slot.records
        }
        if let inFlight = movieFetch, inFlight.fingerprint == fingerprint, inFlight.revalidate == revalidate {
            return commit(await inFlight.task.value, for: .radarr, into: &movieSlot, fingerprint: fingerprint)
        }
        let task = Task<[RadarrLibraryRecord]?, Never> { [weak self] in
            guard let fetched = try? await RadarrClient(config: config).fetchAllMoviesFetched(revalidate: revalidate) else { return nil }
            await self?.note(stale: fetched.isStale, for: .radarr)
            Self.log.notice("radarr records: \(fetched.value.count, privacy: .public) from \(String(describing: fetched.origin), privacy: .public), stale \(fetched.isStale, privacy: .public)")
            return fetched.value
        }
        movieFetch = (fingerprint, revalidate, task)
        let records = await task.value
        if movieFetch?.fingerprint == fingerprint { movieFetch = nil }
        let out = commit(records, for: .radarr, into: &movieSlot, fingerprint: fingerprint)
        LibraryStats.shared.setMovieCount(out.count)
        return out
    }

    public func series(config: ServiceConfig, revalidate: Bool = true) async -> [SonarrLibraryRecord] {
        guard config.isConfigured else { return [] }
        let fingerprint = config.identityFingerprint
        if let slot = seriesSlot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            Self.log.notice("sonarr records: in-memory snapshot")
            return slot.records
        }
        if let inFlight = seriesFetch, inFlight.fingerprint == fingerprint, inFlight.revalidate == revalidate {
            return commit(await inFlight.task.value, for: .sonarr, into: &seriesSlot, fingerprint: fingerprint)
        }
        let task = Task<[SonarrLibraryRecord]?, Never> { [weak self] in
            guard let fetched = try? await SonarrClient(config: config).fetchAllSeriesFetched(revalidate: revalidate) else { return nil }
            await self?.note(stale: fetched.isStale, for: .sonarr)
            Self.log.notice("sonarr records: \(fetched.value.count, privacy: .public) from \(String(describing: fetched.origin), privacy: .public), stale \(fetched.isStale, privacy: .public)")
            return fetched.value
        }
        seriesFetch = (fingerprint, revalidate, task)
        let records = await task.value
        if seriesFetch?.fingerprint == fingerprint { seriesFetch = nil }
        let out = commit(records, for: .sonarr, into: &seriesSlot, fingerprint: fingerprint)
        LibraryStats.shared.setSeriesCount(out.count)
        return out
    }

    /// Lidarr artists. Same slot / in-flight / TTL / keep-stale-on-failure
    /// rules as movies and series — the Library grid and search ownership now
    /// read the artist list from here instead of fetching it twice.
    public func artists(config: ServiceConfig, revalidate: Bool = true) async -> [LidarrLibraryRecord] {
        guard config.isConfigured else { return [] }
        let fingerprint = config.identityFingerprint
        if let slot = artistSlot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            Self.log.notice("lidarr records: in-memory snapshot")
            return slot.records
        }
        if let inFlight = artistFetch, inFlight.fingerprint == fingerprint, inFlight.revalidate == revalidate {
            return commit(await inFlight.task.value, for: .lidarr, into: &artistSlot, fingerprint: fingerprint)
        }
        let task = Task<[LidarrLibraryRecord]?, Never> { [weak self] in
            guard let fetched = try? await LidarrClient(config: config).fetchAllArtistsFetched(revalidate: revalidate) else { return nil }
            await self?.note(stale: fetched.isStale, for: .lidarr)
            Self.log.notice("lidarr records: \(fetched.value.count, privacy: .public) from \(String(describing: fetched.origin), privacy: .public), stale \(fetched.isStale, privacy: .public)")
            return fetched.value
        }
        artistFetch = (fingerprint, revalidate, task)
        let records = await task.value
        if artistFetch?.fingerprint == fingerprint { artistFetch = nil }
        return commit(records, for: .lidarr, into: &artistSlot, fingerprint: fingerprint)
    }

    /// Whisparr scenes/movies — same rules again.
    public func whisparrMovies(config: ServiceConfig, revalidate: Bool = true) async -> [WhisparrLibraryRecord] {
        guard config.isConfigured else { return [] }
        let fingerprint = config.identityFingerprint
        if let slot = whisparrSlot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            Self.log.notice("whisparr records: in-memory snapshot")
            return slot.records
        }
        if let inFlight = whisparrFetch, inFlight.fingerprint == fingerprint, inFlight.revalidate == revalidate {
            return commit(await inFlight.task.value, for: .whisparr, into: &whisparrSlot, fingerprint: fingerprint)
        }
        let task = Task<[WhisparrLibraryRecord]?, Never> { [weak self] in
            guard let fetched = try? await WhisparrClient(config: config).fetchAllMoviesFetched(revalidate: revalidate) else { return nil }
            await self?.note(stale: fetched.isStale, for: .whisparr)
            Self.log.notice("whisparr records: \(fetched.value.count, privacy: .public) from \(String(describing: fetched.origin), privacy: .public), stale \(fetched.isStale, privacy: .public)")
            return fetched.value
        }
        whisparrFetch = (fingerprint, revalidate, task)
        let records = await task.value
        if whisparrFetch?.fingerprint == fingerprint { whisparrFetch = nil }
        return commit(records, for: .whisparr, into: &whisparrSlot, fingerprint: fingerprint)
    }

    /// Whether the records a fetch just produced were the store's old copy.
    private func note(stale: Bool, for source: QueueItem.Source) {
        if stale { servedStale.insert(source) } else { servedStale.remove(source) }
    }

    /// One commit rule for all four sources.
    ///
    /// `nil` means the fetch threw. A failed fetch keeps whatever we had — a
    /// momentarily unreachable arr must not turn into "your library is empty",
    /// which reads as "you own nothing" everywhere downstream — and leaves the
    /// version where it was, so nobody downstream re-unifies for nothing.
    /// An empty-but-successful fetch IS a commit: a genuinely empty library is
    /// an answer, not a failure.
    private func commit<Record: Sendable>(
        _ records: [Record]?,
        for source: QueueItem.Source,
        into slot: inout Slot<Record>?,
        fingerprint: String
    ) -> [Record] {
        // Callers that joined an in-flight fetch reach here too. One fetch is
        // one commit: whoever resumes first writes the slot and bumps, and the
        // rest see a fresh slot and reuse it, so the version never moves
        // without the records moving with it.
        if let slot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            return slot.records
        }
        guard let records else {
            failedSources.insert(source)
            if let slot, slot.fingerprint == fingerprint { return slot.records }
            return []
        }
        failedSources.remove(source)
        slot = Slot(records: records, fetchedAt: Date(), fingerprint: fingerprint)
        versions[source, default: 0] += 1
        return records
    }

    // MARK: - Invalidation

    /// Expire a source's snapshot. Called when an import lands and after the
    /// app itself changes library state, so the next answer can't contradict
    /// the action the user just watched happen.
    ///
    /// The slot is EXPIRED rather than dropped: the next read refetches, and
    /// if that refetch fails the stale records are still there to fall back
    /// on. Dropping it would turn "the arr is down right after an add" into an
    /// empty library.
    public func invalidate(_ source: QueueItem.Source) {
        switch source {
        case .radarr:   movieSlot?.fetchedAt = .distantPast
        case .sonarr:   seriesSlot?.fetchedAt = .distantPast
        case .lidarr:   artistSlot?.fetchedAt = .distantPast
        case .whisparr: whisparrSlot?.fetchedAt = .distantPast
        }
        versions[source, default: 0] += 1
    }

    /// Fire-and-forget form for synchronous call sites (the realtime event
    /// handler runs on the main actor and has nothing to await on).
    public nonisolated func invalidateSoon(_ source: QueueItem.Source) {
        Task { await self.invalidate(source) }
    }

    nonisolated private static func isFresh(_ stamp: Date) -> Bool {
        Date().timeIntervalSince(stamp) < ttl
    }

}
