import Foundation
import Observation
import os

/// One tile of the Library tab's cover grid — a unified projection of the
/// per-arr library records (`RadarrLibraryRecord` & friends). Carries just
/// what the grid renders plus the ids DetailView needs to refetch the full
/// record on tap.
public struct LibraryEntry: Identifiable, Equatable, Sendable {
    /// Coarse ownership state driving the status chip. `partial` only
    /// occurs for multi-file media (Sonarr episodes, Lidarr tracks).
    /// `notAvailable` = monitored, nothing on disk, and nothing grabbable
    /// yet (Radarr: minimumAvailability not met; Sonarr: no aired episodes).
    public enum FileState: Sendable {
        case complete, partial, missing, notAvailable, unmonitored
    }

    public let id: String
    public let source: QueueItem.Source
    /// Arr-internal record id (movie/series/artist) — what DetailView refetches by.
    public let arrId: Int
    /// The title's foreign id — tmdbId (Radarr/Whisparr) or tvdbId (Sonarr),
    /// the key `SearchResult.externalId` carries. Nil for Lidarr artists.
    public var externalId: Int? = nil
    public let title: String
    public let year: Int?
    public let posterURL: URL?
    public let posterRequiresAuth: Bool
    public let state: FileState
    public let sizeOnDisk: Int64
    /// Sonarr: episode files / episodes. Lidarr: track files / tracks.
    /// `nil` for single-file media (Radarr / Whisparr).
    public let fileCount: Int?
    public let totalCount: Int?
    /// The on-disk file's actual quality ("Remux-1080p"). Radarr/Whisparr
    /// only — series and artists have no single file.
    public let fileQuality: String?
    /// The assigned quality profile's name ("Remux + WEB 2160p"). All arrs.
    public let profileName: String?
    /// Custom-format names + score from the on-disk file (Radarr/Whisparr).
    public let customFormats: [String]
    public let customFormatScore: Int
    /// On-disk relative path of the file (Radarr/Whisparr).
    public let fileName: String?
    /// Tooltip garnish (Radarr: genres/runtime/certification; Sonarr: genres).
    public let genres: [String]
    public let runtime: Int?
    public let certification: String?
    /// Split ratings — Radarr carries IMDb and TMDB as SEPARATE sort axes.
    public let ratingImdb: Double?
    public let ratingTmdb: Double?
    /// The source's own single score, for the arrs that ship exactly one:
    /// Sonarr's is TVDB's, Lidarr's comes from its metadata provider. Not
    /// named for either, because it is both — Radarr leaves it nil and uses
    /// the split pair above.
    public let ratingArr: Double?
    /// Radarr-only extras so the tooltip's rating pills match the detail
    /// hero's full set. (`var … = nil`: only the Radarr unify passes them.)
    public var ratingRt: Double? = nil
    public var ratingMetacritic: Double? = nil
    /// Raw arr availability/run state ("released", "inCinemas", "continuing",
    /// "ended", …) — the tooltip maps known values to localized labels.
    public let releaseStatus: String?
    /// Synopsis for the tooltip (Radarr/Sonarr ship it on the library wire;
    /// Lidarr/Whisparr don't).
    public var overview: String? = nil
    /// Folded haystack of every name this entry answers to — its title, its
    /// original-language title, and the arr's alternate titles. The filter
    /// field searches THIS, not `title`, which is how "leon zawodowiec" finds
    /// "Léon: The Professional". Built once per library load; see
    /// `TitleMatch.searchIndex` for why that timing matters.
    ///
    /// Required, not defaulted: an entry whose index is empty matches nothing
    /// at all, so a forgotten construction site would quietly make a whole
    /// source unfilterable. Let the compiler ask.
    public let searchIndex: String
    /// When the title was released / first aired. Nil for sources that ship no
    /// date (Lidarr artists) and for records the arr hasn't dated yet.
    public var releaseDate: Date? = nil
    /// When the title was added to the arr. Every arr ships this one.
    public var dateAdded: Date? = nil

    /// Sort key for "Release date". Falls back to the start of `year` so a
    /// record with only a year still sorts among the dated ones instead of
    /// sinking to the bottom — a year IS a release date, just a coarse one.
    /// Undated titles sort last (ascending order reverses this).
    public var releaseSortKey: Date {
        if let releaseDate { return releaseDate }
        guard let year else { return .distantPast }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year)) ?? .distantPast
    }
}

/// Projects each arr's full library into the Library tab's grid entries. The
/// records themselves come from `LibraryIndex` — the one cache the whole app
/// shares — and the whole library arrives in a single `/api/v3/<entity>` call
/// (a few MB of JSON for a few thousand titles), so the unify runs only when
/// the index's version for a source moves. Switching tabs or sources renders
/// instantly from the already-unified entries.
@MainActor
@Observable
public final class LibraryViewModel {
    public private(set) var entries: [QueueItem.Source: [LibraryEntry]] = [:]
    public private(set) var loading: Set<QueueItem.Source> = []
    public private(set) var loadFailed: Set<QueueItem.Source> = []

    @ObservationIgnored private static let log = Logger(category: "Library")

    /// Sorted views of `entries`, memoized per (source, sort axis). The
    /// Library tab used to sort inside `body` — a localized title sort over
    /// ~3k entries costs ~20ms+ per body pass, and body runs several times
    /// just entering the tab, which read as a hitch on every visit. Cached
    /// here (not in the view) because the tab view is torn down on every
    /// tab switch; cleared whenever a source refetches.
    /// `@ObservationIgnored`: `sorted(_:cacheKey:using:)` fills this from
    /// inside `body`, and an observed mutation there would invalidate the
    /// very body that is running.
    @ObservationIgnored private var sortCache: [QueueItem.Source: [String: [LibraryEntry]]] = [:]

    /// The `LibraryIndex` version each source's `entries` were unified from.
    /// The grid is a PROJECTION of the index, not a second cache: it re-unifies
    /// when — and only when — the index says its records changed. The old
    /// 5-minute TTL of its own is what made an add read "not owned" in the grid
    /// for minutes after the index already knew better.
    private var indexVersions: [QueueItem.Source: Int] = [:]

    public init() {}

    /// `entries[source]` sorted by the given axis, memoized until the next
    /// refetch. `cacheKey` identifies the axis (the comparator itself can't
    /// be compared); callers must keep key ↔ comparator consistent.
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

    /// The default (title) axis' comparator — lives on the model so the
    /// post-fetch pre-warm and the view's `.title` sort are one definition
    /// under one cache key.
    public nonisolated static func titleAscending(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    /// Project `source`'s library into grid entries if the index moved under
    /// us (or we have nothing yet). `force` expires the index first, so ⌘R is
    /// a real refetch and not a re-unify of the same records.
    public func loadIfNeeded(source: QueueItem.Source, config: ServiceConfig, force: Bool = false) async {
        if force { await LibraryIndex.shared.invalidate(source) }
        let indexVersion = await LibraryIndex.shared.version(for: source)
        if !force, entries[source] != nil, indexVersions[source] == indexVersion {
            return
        }
        guard !loading.contains(source) else { return }
        loading.insert(source)
        loadFailed.remove(source)
        defer { loading.remove(source) }

        // Profile names resolve qualityProfileId → "HD-1080p" for rows without
        // a file (and for Sonarr/Lidarr, which have no single file). One cheap
        // call. Failure degrades to no quality caption, not a failed load.
        let profiles = await SearchClient.profileNameMap(config: config, source: source)
        let fresh: [LibraryEntry]
        switch source {
        case .radarr:
            let movies = await LibraryIndex.shared.movies(config: config)
            // Alternate titles are what let the filter find a film by its
            // Polish or German name. Best-effort, and only paid when the movie
            // list actually changed — reaching this line at all means the
            // index version moved.
            let alts = await RadarrClient(config: config).alternateTitleMap(for: movies)
            fresh = Self.unify(movies, baseURL: config.baseURL, profiles: profiles, alternateTitles: alts)
        case .sonarr:
            fresh = Self.unify(await LibraryIndex.shared.series(config: config),
                               baseURL: config.baseURL, profiles: profiles)
        case .lidarr:
            fresh = Self.unify(await LibraryIndex.shared.artists(config: config),
                               baseURL: config.baseURL, profiles: profiles)
        case .whisparr:
            fresh = Self.unify(await LibraryIndex.shared.whisparrMovies(config: config),
                               baseURL: config.baseURL, profiles: profiles)
        }

        // The index swallows the error and hands back a stale snapshot (or
        // nothing). Keep any stale cache on screen; the flag only surfaces an
        // error state when there is nothing at all to show. That quietness is
        // right for the UI and wrong for diagnosis, so the failure is said out
        // loud in the log.
        if await LibraryIndex.shared.fetchFailed(source) {
            Self.log.error("\(source.rawValue, privacy: .public) library load failed — index reports an unreachable arr")
            if entries[source] == nil {
                loadFailed.insert(source)
                return
            }
        }

        entries[source] = fresh
        sortCache[source] = nil
        // Pre-warm the default axis so the first Library visit after a fetch
        // renders without paying the sort inside body.
        _ = sorted(source, cacheKey: "title", using: Self.titleAscending)
        indexVersions[source] = await LibraryIndex.shared.version(for: source)
        Self.logAliasCoverage(fresh, source: source)
    }

    // MARK: - Diagnostics

    /// How many entries came back knowing more than one name. Whether an arr
    /// supplies alternate titles at all varies by product and version, and the
    /// symptom of "none" is invisible — the filter just quietly reaches less
    /// far — so it gets said out loud once per load.
    ///
    /// Levels split by whether there is anything to say. A library that DOES
    /// supply alternate titles is a healthy load, and loads repeat — `.debug`,
    /// which stays out of the persistent store. Zero coverage is the case
    /// somebody eventually asks about ("search doesn't find X by its other
    /// name"), so that one is `.notice` and survives to be read back with
    /// `log show`, which never returns `.info`/`.debug`.
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

    private static func unify(_ records: [RadarrLibraryRecord], baseURL: String, profiles: [Int: String],
                              alternateTitles: [Int: [String]] = [:]) -> [LibraryEntry] {
        records.compactMap { r in
            guard let id = r.id, let title = r.title else { return nil }
            let (poster, auth) = (r.images ?? []).posterURL(
                baseURL: baseURL, mediaServerKeys: r.mediaServerKeys
            )
            return LibraryEntry(
                id: "radarr-\(id)", source: .radarr, arrId: id, externalId: r.tmdbId, title: title,
                year: r.year, posterURL: poster, posterRequiresAuth: auth,
                state: .movie(monitored: r.monitored, hasFile: r.hasFile ?? false,
                             available: r.isAvailable ?? true),
                sizeOnDisk: r.sizeOnDisk ?? 0, fileCount: nil, totalCount: nil,
                fileQuality: r.movieFile?.qualityName,
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
                // Earliest of the three: cinema, digital, physical.
                releaseDate: [r.inCinemas, r.digitalRelease, r.physicalRelease]
                    .compactMap { $0.flatMap(parseArrDate) }.min(),
                dateAdded: r.added.flatMap(parseArrDate)
            )
        }
    }

    private static func unify(_ records: [SonarrLibraryRecord], baseURL: String, profiles: [Int: String]) -> [LibraryEntry] {
        records.compactMap { r in
            guard let id = r.id, let title = r.title else { return nil }
            let (poster, auth) = (r.images ?? []).posterURL(
                baseURL: baseURL, mediaServerKeys: r.mediaServerKeys
            )
            let counts = r.episodeFileCounts
            return LibraryEntry(
                id: "sonarr-\(id)", source: .sonarr, arrId: id, externalId: r.tvdbId, title: title,
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
        }
    }

    private static func unify(_ records: [LidarrLibraryRecord], baseURL: String, profiles: [Int: String]) -> [LibraryEntry] {
        records.compactMap { r in
            guard let id = r.id, let name = r.artistName else { return nil }
            let (poster, auth) = (r.images ?? []).posterURL(baseURL: baseURL)
            let files = r.statistics?.trackFileCount ?? 0
            let total = r.statistics?.trackCount ?? 0
            return LibraryEntry(
                id: "lidarr-\(id)", source: .lidarr, arrId: id, title: name,
                year: nil, posterURL: poster, posterRequiresAuth: auth,
                state: .resolve(monitored: r.monitored, complete: total > 0 && files >= total, partial: files > 0),
                sizeOnDisk: r.statistics?.sizeOnDisk ?? 0, fileCount: files, totalCount: total,
                fileQuality: nil,
                profileName: r.qualityProfileId.flatMap { profiles[$0] },
                customFormats: [], customFormatScore: 0, fileName: nil,
                genres: [], runtime: nil, certification: nil,
                ratingImdb: nil, ratingTmdb: nil, ratingArr: r.ratings?.value,
                releaseStatus: nil,
                // Lidarr has no alternate artist names on the wire — the one
                // visible name is the whole index.
                searchIndex: TitleMatch.searchIndex([name]),
                dateAdded: r.added.flatMap(parseArrDate)
            )
        }
    }

    private static func unify(_ records: [WhisparrLibraryRecord], baseURL: String, profiles: [Int: String]) -> [LibraryEntry] {
        records.compactMap { r in
            guard let id = r.id, let title = r.title else { return nil }
            let (poster, auth) = (r.images ?? []).posterURL(baseURL: baseURL)
            return LibraryEntry(
                id: "whisparr-\(id)", source: .whisparr, arrId: id, externalId: r.tmdbId, title: title,
                year: r.year, posterURL: poster, posterRequiresAuth: auth,
                state: .movie(monitored: r.monitored, hasFile: r.hasFile ?? false,
                             available: r.isAvailable ?? true),
                sizeOnDisk: r.sizeOnDisk ?? 0, fileCount: nil, totalCount: nil,
                fileQuality: r.movieFile?.qualityName,
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
