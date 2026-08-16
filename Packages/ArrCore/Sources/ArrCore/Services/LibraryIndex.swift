import Foundation

/// One cached copy of the Sonarr / Radarr libraries, shared by every tool that
/// needs to know what the user owns.
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

    public static let shared = LibraryIndex()

    /// Backstop for changes no event tells us about. Long on purpose: this is
    /// the heaviest call the app makes, and events cover the urgent cases.
    public static let ttl: TimeInterval = 10 * 60

    private struct Slot<Record: Sendable>: Sendable {
        var records: [Record]
        var fetchedAt: Date
        /// The config the snapshot was built from — a changed URL or key
        /// invalidates it immediately rather than at the next `ttl`.
        var fingerprint: String
    }

    private var movieSlot: Slot<RadarrLibraryRecord>?
    private var seriesSlot: Slot<SonarrLibraryRecord>?
    /// One in-flight fetch per source. Without it, three tools called in the
    /// same turn each start their own fetch of a cold cache.
    private var movieFetch: Task<[RadarrLibraryRecord], Never>?
    private var seriesFetch: Task<[SonarrLibraryRecord], Never>?

    init() {}

    // MARK: - Reads

    public func movies(config: ServiceConfig) async -> [RadarrLibraryRecord] {
        guard config.isConfigured else { return [] }
        let fingerprint = Self.fingerprint(config)
        if let slot = movieSlot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            return slot.records
        }
        if let inFlight = movieFetch { return await inFlight.value }
        let task = Task<[RadarrLibraryRecord], Never> {
            (try? await RadarrClient(config: config).fetchAllMovies()) ?? []
        }
        movieFetch = task
        let records = await task.value
        movieFetch = nil
        // A failed fetch keeps whatever we had: a momentarily unreachable arr
        // must not turn into "your library is empty", which reads as "you own
        // nothing" everywhere downstream.
        if records.isEmpty, let slot = movieSlot, slot.fingerprint == fingerprint {
            return slot.records
        }
        movieSlot = Slot(records: records, fetchedAt: Date(), fingerprint: fingerprint)
        return records
    }

    public func series(config: ServiceConfig) async -> [SonarrLibraryRecord] {
        guard config.isConfigured else { return [] }
        let fingerprint = Self.fingerprint(config)
        if let slot = seriesSlot, slot.fingerprint == fingerprint, Self.isFresh(slot.fetchedAt) {
            return slot.records
        }
        if let inFlight = seriesFetch { return await inFlight.value }
        let task = Task<[SonarrLibraryRecord], Never> {
            (try? await SonarrClient(config: config).fetchAllSeries()) ?? []
        }
        seriesFetch = task
        let records = await task.value
        seriesFetch = nil
        if records.isEmpty, let slot = seriesSlot, slot.fingerprint == fingerprint {
            return slot.records
        }
        seriesSlot = Slot(records: records, fetchedAt: Date(), fingerprint: fingerprint)
        return records
    }

    // MARK: - Invalidation

    /// Drop a source's snapshot. Called when an import lands and after the
    /// agent itself changes library state, so the next answer can't contradict
    /// the action the user just watched happen.
    public func invalidate(_ source: QueueItem.Source) {
        switch source {
        case .radarr: movieSlot = nil
        case .sonarr: seriesSlot = nil
        default: break
        }
    }

    /// Fire-and-forget form for synchronous call sites (the realtime event
    /// handler runs on the main actor and has nothing to await on).
    public nonisolated func invalidateSoon(_ source: QueueItem.Source) {
        Task { await self.invalidate(source) }
    }

    private static func isFresh(_ stamp: Date) -> Bool {
        Date().timeIntervalSince(stamp) < ttl
    }

    private static func fingerprint(_ config: ServiceConfig) -> String {
        "\(config.baseURL)|\(config.apiKey.count)"
    }
}
