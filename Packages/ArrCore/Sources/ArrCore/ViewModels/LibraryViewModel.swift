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

/// Fetches + caches each arr's full library for the Library tab. The whole
/// library comes down in one `/api/v3/<entity>` call (a few MB of JSON for a
/// few thousand titles), so results are kept per source and only refetched
/// when stale — switching tabs or sources inside the TTL renders instantly
/// from cache.
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

    private var fetchedAt: [QueueItem.Source: Date] = [:]
    /// Refetch cadence while the user keeps coming back to the tab. Long on
    /// purpose: libraries change on add/import, not every minute, and the
    /// fetch is the single heaviest arr call the app makes.
    private let ttl: TimeInterval = 300

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

    /// Load `source`'s library if it isn't cached fresh. `force` bypasses the
    /// TTL (used by ⌘R / explicit refresh).
    public func loadIfNeeded(source: QueueItem.Source, config: ServiceConfig, force: Bool = false) async {
        if !force,
           let stamp = fetchedAt[source],
           Date().timeIntervalSince(stamp) < ttl,
           entries[source] != nil {
            return
        }
        guard !loading.contains(source) else { return }
        loading.insert(source)
        loadFailed.remove(source)
        defer { loading.remove(source) }

        do {
            // Profile names resolve qualityProfileId → "HD-1080p" for rows
            // without a file (and for Sonarr/Lidarr, which have no single
            // file). One cheap call, fetched alongside the library. Failure
            // degrades to no quality caption, not a failed load.
            let profiles = await SearchClient.profileNameMap(config: config, source: source)
            let fresh: [LibraryEntry]
            switch source {
            case .radarr:
                let client = RadarrClient(config: config)
                let movies = try await client.fetchAllMovies()
                // Alternate titles are what let the filter find a film by its
                // Polish or German name. Best-effort and awaited after the
                // library itself, so a slow or absent `/alttitle` costs reach,
                // never the load.
                let alts = await client.alternateTitleMap(for: movies)
                fresh = Self.unify(movies, baseURL: config.baseURL, profiles: profiles, alternateTitles: alts)
            case .sonarr:
                fresh = Self.unify(try await SonarrClient(config: config).fetchAllSeries(), baseURL: config.baseURL, profiles: profiles)
            case .lidarr:
                fresh = Self.unify(try await LidarrClient(config: config).fetchAllArtists(), baseURL: config.baseURL, profiles: profiles)
            case .whisparr:
                fresh = Self.unify(try await WhisparrClient(config: config).fetchAllMovies(), baseURL: config.baseURL, profiles: profiles)
            }
            entries[source] = fresh
            sortCache[source] = nil
            // Pre-warm the default axis so the first Library visit after a
            // fetch renders without paying the sort inside body.
            _ = sorted(source, cacheKey: "title", using: Self.titleAscending)
            fetchedAt[source] = Date()
            Self.logAliasCoverage(fresh, source: source)
        } catch {
            // Keep any stale cache on screen; the flag only surfaces an error
            // state when there's nothing at all to show. That quietness is
            // right for the UI and wrong for diagnosis — the reason the load
            // failed exists nowhere else, so it goes to the log. Detail stays
            // `.private`: a URLError carries the failing URL.
            Self.log.error(
                "\(source.rawValue, privacy: .public) library load failed: \(error.userFacingMessage, privacy: .public) | \(String(reflecting: error), privacy: .private)"
            )
            loadFailed.insert(source)
        }
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

    private static func state(monitored: Bool?, complete: Bool, partial: Bool, available: Bool = true) -> LibraryEntry.FileState {
        guard monitored ?? false else { return .unmonitored }
        if complete { return .complete }
        if partial { return .partial }
        return available ? .missing : .notAvailable
    }

    private static func unify(_ records: [RadarrLibraryRecord], baseURL: String, profiles: [Int: String],
                              alternateTitles: [Int: [String]] = [:]) -> [LibraryEntry] {
        records.compactMap { r in
            guard let id = r.id, let title = r.title else { return nil }
            let (poster, auth) = (r.images ?? []).posterURL(
                baseURL: baseURL, mediaServerKeys: r.mediaServerKeys
            )
            return LibraryEntry(
                id: "radarr-\(id)", source: .radarr, arrId: id, title: title,
                year: r.year, posterURL: poster, posterRequiresAuth: auth,
                state: state(monitored: r.monitored, complete: r.hasFile ?? false, partial: false,
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
            let files = r.statistics?.episodeFileCount ?? 0
            let total = r.statistics?.episodeCount ?? 0
            return LibraryEntry(
                id: "sonarr-\(id)", source: .sonarr, arrId: id, title: title,
                year: r.year, posterURL: poster, posterRequiresAuth: auth,
                state: state(monitored: r.monitored, complete: total > 0 && files >= total, partial: files > 0,
                             available: total > 0),
                sizeOnDisk: r.statistics?.sizeOnDisk ?? 0, fileCount: files, totalCount: total,
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
                state: state(monitored: r.monitored, complete: total > 0 && files >= total, partial: files > 0),
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
                id: "whisparr-\(id)", source: .whisparr, arrId: id, title: title,
                year: r.year, posterURL: poster, posterRequiresAuth: auth,
                state: state(monitored: r.monitored, complete: r.hasFile ?? false, partial: false,
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
