import Foundation
import Observation
import os
import MediaKit

/// One Library grid tile, unified across the per-arr library records.
public struct LibraryEntry: Identifiable, Equatable, Sendable, Codable {
    /// `partial` only for multi-file media. `notAvailable` = monitored, nothing on disk, nothing grabbable yet
    /// (Radarr: minimumAvailability not met; Sonarr: no aired episodes).
    nonisolated public enum FileState: String, Sendable, Codable {
        case complete, partial, missing, notAvailable, unmonitored
    }

    public let id: String
    public let source: QueueItem.Source
    public let arrId: Int
    /// tmdbId (Radarr/Whisparr) or tvdbId (Sonarr), as `SearchResult.externalId` carries it. Nil for Lidarr.
    public var externalId: Int? = nil
    /// Where the arr's web UI files it: `titleSlug`, or Lidarr's `foreignArtistId`.
    public var slug: String? = nil
    /// Resolved once at projection, not per body pass: the index is lock-guarded and a scrolling grid
    /// would take that lock every frame.
    public var watched: Bool = false
    public let title: String
    public let year: Int?
    public let posterURL: URL?
    public let posterRequiresAuth: Bool
    public let state: FileState
    public let sizeOnDisk: Int64
    /// Sonarr: episode files / episodes. Lidarr: track files / tracks. `nil` for single-file media.
    public let fileCount: Int?
    public let totalCount: Int?
    /// Radarr/Whisparr only — series and artists have no single file.
    public let fileQuality: String?
    public let profileName: String?
    public let customFormats: [String]
    public let customFormatScore: Int
    public let fileName: String?
    public let genres: [String]
    public let runtime: Int?
    public let certification: String?
    /// Radarr carries IMDb and TMDB as separate sort axes.
    public let ratingImdb: Double?
    public let ratingTmdb: Double?
    /// The arr's single score where it ships one (Sonarr: TVDB's; Lidarr: its metadata provider's). Radarr uses the pair above.
    public let ratingArr: Double?
    /// Radarr-only, so the tooltip's rating pills match the detail hero.
    public var ratingRt: Double? = nil
    public var ratingMetacritic: Double? = nil
    public let releaseStatus: String?
    /// Radarr/Sonarr ship it on the library wire; Lidarr/Whisparr don't.
    public var overview: String? = nil
    /// Folded title + original title + alternate titles; the filter searches this, not `title`.
    /// Required so a forgotten construction site can't silently make a source unfilterable.
    public let searchIndex: String
    public var releaseDate: Date? = nil
    public var dateAdded: Date? = nil

    /// Falls back to the start of `year` so year-only records sort among the dated ones. Undated sort last.
    public var releaseSortKey: Date {
        if let releaseDate { return releaseDate }
        guard let year else { return .distantPast }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year)) ?? .distantPast
    }
}

/// Projects each arr's library from `LibraryIndex` into grid entries; re-unifies only when the index's
/// version for a source moves.
@Observable
public final class LibraryViewModel {
    public private(set) var entries: [QueueItem.Source: [LibraryEntry]] = [:]
    public private(set) var loading: Set<QueueItem.Source> = []
    public private(set) var loadFailed: Set<QueueItem.Source> = []

    @ObservationIgnored private static let log = Logger(category: "Library")

    /// Memoized: a localized sort over ~3k entries costs ~20ms per body pass. `@ObservationIgnored` because
    /// it is filled from inside `body`, where an observed mutation would invalidate the running body.
    @ObservationIgnored private var sortCache: [QueueItem.Source: [String: [LibraryEntry]]] = [:]

    /// Memoized like `sortCache`: the filter strip re-evaluates while the grid scrolls.
    @ObservationIgnored private var filterCache: [QueueItem.Source: [String: [LibraryEntry]]] = [:]
    @ObservationIgnored private var countCache: [QueueItem.Source: [String: Int]] = [:]

    /// Lives here because the tab view is torn down on tab switch; `@ObservationIgnored` because it is
    /// written every frame of a drag.
    @ObservationIgnored public var gridAnchor: [QueueItem.Source: LibraryEntry.ID] = [:]

    /// The grid re-unifies when, and only when, the index's version for the source moves.
    private var indexVersions: [QueueItem.Source: LibraryIndex.Version] = [:]

    public init() {}

    /// `cacheKey` identifies the axis (a comparator can't be compared); callers keep key ↔ comparator consistent.
    public func sorted(
        _ source: QueueItem.Source,
        cacheKey: String,
        using comparator: (LibraryEntry, LibraryEntry) -> Bool
    ) -> [LibraryEntry] {
        if let hit = sortCache[source]?[cacheKey] { return hit }
        let out = (entries[source] ?? []).sorted(by: comparator)
        sortCache[source, default: [:]][cacheKey] = out
        return out
    }

    /// `cacheKey` must identify sort axis AND filter together.
    public func visible(
        _ source: QueueItem.Source,
        cacheKey: String,
        from sorted: [LibraryEntry],
        where predicate: (LibraryEntry) -> Bool
    ) -> [LibraryEntry] {
        if let hit = filterCache[source]?[cacheKey] { return hit }
        let out = sorted.filter(predicate)
        filterCache[source, default: [:]][cacheKey] = out
        return out
    }

    public func count(
        _ source: QueueItem.Source,
        cacheKey: String,
        over base: [LibraryEntry],
        where predicate: (LibraryEntry) -> Bool
    ) -> Int {
        if let hit = countCache[source]?[cacheKey] { return hit }
        let out = base.count(where: predicate)
        countCache[source, default: [:]][cacheKey] = out
        return out
    }

    /// Must match the key the Library tab builds for title-ascending, or the first paint re-sorts inside `body`.
    public static let defaultSortCacheKey = "title|asc"

    public nonisolated static func titleAscending(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    /// The first visit paints from MediaKit's on-disk store and refreshes behind it; later visits use the TTL path.
    @ObservationIgnored private var revalidated: Set<QueueItem.Source> = []

    /// `force` expires the index first, so ⌘R is a real refetch.
    public func loadIfNeeded(source: QueueItem.Source, config: ServiceConfig, force: Bool = false) async {
        let revalidate = force || revalidated.contains(source)
        if force { await LibraryIndex.shared.invalidate(source, config: config) }
        let indexVersion = await LibraryIndex.shared.version(for: source, config: config)
        if !force, entries[source] != nil, indexVersions[source] == indexVersion {
            return
        }
        // Paint the saved grid first; everything below happens behind a screen that already has covers.
        if entries[source] == nil {
            let paint = AppSignpost.library.beginInterval("snapshot paint")
            if let saved = await LibrarySnapshotStore.load(source, fingerprint: config.identityFingerprint) {
                // Stored in title order, so this skips the localized sort.
                commit(saved, byTitle: saved, for: source, version: nil)
                Self.log.notice("\(source.rawValue, privacy: .public) library painted from snapshot: \(saved.count, privacy: .public) titles")
            }
            AppSignpost.library.endInterval("snapshot paint", paint)
        }
        guard !loading.contains(source) else { return }
        let interval = AppSignpost.library.beginInterval("library load")
        loading.insert(source)
        loadFailed.remove(source)
        defer {
            loading.remove(source)
            AppSignpost.library.endInterval("library load", interval)
        }

        // Failure degrades to no quality caption. The cache-first pass takes only what is cached, so the request
        // doesn't delay the first paint.
        let profiles = revalidate
            ? await SearchClient.profileNameMap(config: config, source: source)
            : await SearchClient.cachedProfileNameMap(config: config, source: source)
        AppSignpost.library.emitEvent("profiles read")
        let baseURL = config.baseURL
        let projection: Projection
        let failed: Bool
        let stale: Bool
        switch source {
        case .radarr:
            let read = await LibraryIndex.shared.moviesRead(config: config, revalidate: revalidate)
            let movies = read.records
            failed = read.failed; stale = read.stale
            // Alternate titles let the filter find a film by its Polish or German name. They cost their own request
            // when Radarr doesn't inline them, so the cache-first paint skips them.
            let alts = revalidate
                ? await ServiceHandles.radarr(config: config).alternateTitleMap(for: movies)
                : [:]
            projection = await Self.project {
                Self.unify(movies, baseURL: baseURL, profiles: profiles, alternateTitles: alts)
            }
        case .sonarr:
            let read = await LibraryIndex.shared.seriesRead(config: config, revalidate: revalidate)
            failed = read.failed; stale = read.stale
            projection = await Self.project { Self.unify(read.records, baseURL: baseURL, profiles: profiles) }
        case .lidarr:
            let read = await LibraryIndex.shared.artistsRead(config: config, revalidate: revalidate)
            failed = read.failed; stale = read.stale
            projection = await Self.project { Self.unify(read.records, baseURL: baseURL, profiles: profiles) }
        case .whisparr:
            let read = await LibraryIndex.shared.whisparrMoviesRead(config: config, revalidate: revalidate)
            failed = read.failed; stale = read.stale
            projection = await Self.project { Self.unifyWhisparr(read.records, baseURL: baseURL, profiles: profiles) }
        }

        Self.log.notice("\(source.rawValue, privacy: .public) load: \(projection.entries.count, privacy: .public) entries projected (revalidate \(revalidate, privacy: .public))")

        // On failure the index returns a stale snapshot or nothing, so never commit: an empty `fresh` over a good grid
        // reads "you own nothing". Leaving `indexVersions` unwritten makes the next load retry.
        if failed {
            Self.log.error("\(source.rawValue, privacy: .public) library load failed — index reports an unreachable arr")
            if entries[source] == nil { loadFailed.insert(source) }
            return
        }

        commit(projection.entries, byTitle: projection.byTitle, for: source,
               version: await LibraryIndex.shared.version(for: source, config: config))
        LibrarySnapshotStore.save(projection.byTitle, source: source, fingerprint: config.identityFingerprint)
        Self.logAliasCoverage(projection.entries, source: source)

        // Painted from the stored copy; now revalidate under the visible grid. A network first pass needs no second one.
        if !revalidate {
            revalidated.insert(source)
            if stale {
                Self.log.notice("\(source.rawValue, privacy: .public) library painted from the store — refreshing behind the grid")
                Task { [weak self] in
                    await self?.loadIfNeeded(source: source, config: config, force: true)
                }
            }
        }
    }

    /// `version` is nil for the snapshot paint, which must not mark the index as projected.
    private func commit(_ entries: [LibraryEntry], byTitle: [LibraryEntry],
                        for source: QueueItem.Source, version: LibraryIndex.Version?) {
        self.entries[source] = entries
        // The default axis arrives sorted, so the first visit doesn't pay the sort inside body.
        sortCache[source] = [Self.defaultSortCacheKey: byTitle]
        filterCache[source] = nil
        countCache[source] = nil
        if let version { indexVersions[source] = version }
    }

    private struct Projection: Sendable {
        let entries: [LibraryEntry]
        let byTitle: [LibraryEntry]
    }

    /// Off the main actor: ICU folding and a localized sort over thousands of titles stalled the first visit.
    nonisolated private static func project(
        _ unify: @escaping @Sendable () -> [LibraryEntry]
    ) async -> Projection {
        await Task.detached(priority: .userInitiated) {
            let entries = unify()
            return Projection(entries: entries, byTitle: entries.sorted(by: titleAscending))
        }.value
    }

    // MARK: - Diagnostics

    /// Whether an arr supplies alternate titles varies by product and version, and "none" is invisible in the UI.
    /// Zero coverage is `.notice` so it can be read back; healthy loads stay `.debug`.
    private static func logAliasCoverage(_ entries: [LibraryEntry], source: QueueItem.Source) {
        let withAliases = entries.count { $0.searchIndex.contains("\n") }
        let line = "\(source.rawValue) library: \(entries.count) titles, \(withAliases) with alternate titles"
        if withAliases == 0 && !entries.isEmpty {
            Self.log.notice("\(line, privacy: .public) — alias search will not reach past primary titles")
        } else {
            Self.log.debug("\(line, privacy: .public)")
        }
    }

    // MARK: - Unify

    nonisolated private static func unify(_ records: [ArrMovie], baseURL: String, profiles: [Int: String],
                              alternateTitles: [Int: [String]] = [:]) -> [LibraryEntry] {
        records.compactMap { r in
            guard let id = r.id else { return nil }
            let title = r.title
            let keys = r.mediaServerKeys
            let (poster, auth) = (r.images ?? []).posterURL(
                baseURL: baseURL, mediaServerKeys: keys
            )
            var entry = LibraryEntry(
                id: "radarr-\(id)", source: .radarr, arrId: id, externalId: r.tmdbId, slug: r.titleSlug, title: title,
                year: r.year, posterURL: poster, posterRequiresAuth: auth,
                state: .movie(monitored: r.monitored, hasFile: r.hasFile ?? false,
                             available: r.isAvailable ?? true),
                sizeOnDisk: r.sizeOnDisk ?? 0, fileCount: nil, totalCount: nil,
                fileQuality: r.movieFile?.quality?.name,
                profileName: r.qualityProfileId.flatMap { profiles[$0] },
                customFormats: (r.movieFile?.customFormats ?? []).map(\.name),
                customFormatScore: r.movieFile?.customFormatScore ?? 0,
                fileName: r.movieFile?.relativePath,
                genres: r.genres ?? [], runtime: r.runtime, certification: r.certification,
                ratingImdb: r.ratings?.imdb?.value, ratingTmdb: r.ratings?.tmdb?.value, ratingArr: nil,
                ratingRt: r.ratings?.rottenTomatoes?.value,
                ratingMetacritic: r.ratings?.metacritic?.value,
                releaseStatus: r.status,
                overview: r.overview,
                searchIndex: TitleMatch.searchIndex(
                    [title, r.originalTitle] + (alternateTitles[id] ?? []).map { Optional($0) }),
                releaseDate: [r.inCinemas, r.digitalRelease, r.physicalRelease]
                    .compactMap { $0.flatMap(parseArrDate) }.min(),
                dateAdded: r.added.flatMap(parseArrDate)
            )
            entry.watched = MediaServerIndex.shared.isWatched(keys)
            return entry
        }
    }

    nonisolated private static func unify(_ records: [ArrSeries], baseURL: String, profiles: [Int: String]) -> [LibraryEntry] {
        records.compactMap { r in
            guard let id = r.id else { return nil }
            let title = r.title
            let keys = r.mediaServerKeys
            let (poster, auth) = (r.images ?? []).posterURL(
                baseURL: baseURL, mediaServerKeys: keys
            )
            let counts = r.episodeFileCounts
            var entry = LibraryEntry(
                id: "sonarr-\(id)", source: .sonarr, arrId: id, externalId: r.tvdbId, slug: r.titleSlug, title: title,
                year: r.year, posterURL: poster, posterRequiresAuth: auth,
                state: .series(monitored: r.monitored, counts: counts),
                sizeOnDisk: r.statistics?.sizeOnDisk ?? 0, fileCount: counts.have, totalCount: counts.total,
                fileQuality: nil,
                profileName: r.qualityProfileId.flatMap { profiles[$0] },
                customFormats: [], customFormatScore: 0, fileName: nil,
                genres: r.genres ?? [], runtime: nil, certification: nil,
                ratingImdb: nil, ratingTmdb: nil, ratingArr: r.ratings?.value,
                releaseStatus: r.status,
                overview: r.overview,
                searchIndex: TitleMatch.searchIndex(
                    [title] + (r.alternateTitles ?? []).map(\.title)),
                releaseDate: r.firstAired.flatMap(parseArrDate),
                dateAdded: r.added.flatMap(parseArrDate)
            )
            entry.watched = MediaServerIndex.shared.isWatched(keys)
            return entry
        }
    }

    nonisolated private static func unify(_ records: [ArrArtist], baseURL: String, profiles: [Int: String]) -> [LibraryEntry] {
        records.compactMap { r in
            guard let id = r.id, let name = r.artistName else { return nil }
            let (poster, auth) = (r.images ?? []).posterURL(baseURL: baseURL)
            let files = r.statistics?.trackFileCount ?? 0
            let total = r.statistics?.trackCount ?? 0
            return LibraryEntry(
                id: "lidarr-\(id)", source: .lidarr, arrId: id, slug: r.foreignArtistId, title: name,
                year: nil, posterURL: poster, posterRequiresAuth: auth,
                state: .resolve(monitored: r.monitored, complete: total > 0 && files >= total, partial: files > 0),
                sizeOnDisk: r.statistics?.sizeOnDisk ?? 0, fileCount: files, totalCount: total,
                fileQuality: nil,
                profileName: r.qualityProfileId.flatMap { profiles[$0] },
                customFormats: [], customFormatScore: 0, fileName: nil,
                genres: [], runtime: nil, certification: nil,
                ratingImdb: nil, ratingTmdb: nil, ratingArr: r.ratings?.value,
                releaseStatus: nil,
                // Lidarr has no alternate artist names on the wire.
                searchIndex: TitleMatch.searchIndex([name]),
                dateAdded: r.added.flatMap(parseArrDate)
            )
        }
    }

    nonisolated private static func unifyWhisparr(_ records: [ArrMovie], baseURL: String, profiles: [Int: String]) -> [LibraryEntry] {
        records.compactMap { r in
            guard let id = r.id else { return nil }
            let title = r.title
            let (poster, auth) = (r.images ?? []).posterURL(baseURL: baseURL)
            return LibraryEntry(
                id: "whisparr-\(id)", source: .whisparr, arrId: id, externalId: r.tmdbId, slug: r.titleSlug, title: title,
                year: r.year, posterURL: poster, posterRequiresAuth: auth,
                state: .movie(monitored: r.monitored, hasFile: r.hasFile ?? false,
                             available: r.isAvailable ?? true),
                sizeOnDisk: r.sizeOnDisk ?? 0, fileCount: nil, totalCount: nil,
                fileQuality: r.movieFile?.quality?.name,
                profileName: r.qualityProfileId.flatMap { profiles[$0] },
                customFormats: (r.movieFile?.customFormats ?? []).map(\.name),
                customFormatScore: r.movieFile?.customFormatScore ?? 0,
                fileName: r.movieFile?.relativePath,
                genres: [], runtime: nil, certification: nil,
                ratingImdb: nil, ratingTmdb: nil, ratingArr: nil,
                releaseStatus: r.status,
                searchIndex: TitleMatch.searchIndex([title]),
                dateAdded: r.added.flatMap(parseArrDate)
            )
        }
    }
}
