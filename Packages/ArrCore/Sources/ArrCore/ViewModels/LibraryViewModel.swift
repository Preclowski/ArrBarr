import Foundation
import Observation

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
    /// Split ratings — Radarr carries IMDb and TMDB as SEPARATE sort axes;
    /// Sonarr has a single TVDB score. Others: nothing on the library wire.
    public let ratingImdb: Double?
    public let ratingTmdb: Double?
    public let ratingTvdb: Double?
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

    private var fetchedAt: [QueueItem.Source: Date] = [:]
    /// Refetch cadence while the user keeps coming back to the tab. Long on
    /// purpose: libraries change on add/import, not every minute, and the
    /// fetch is the single heaviest arr call the app makes.
    private let ttl: TimeInterval = 300

    public init() {}

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
                fresh = Self.unify(try await RadarrClient(config: config).fetchAllMovies(), baseURL: config.baseURL, profiles: profiles)
            case .sonarr:
                fresh = Self.unify(try await SonarrClient(config: config).fetchAllSeries(), baseURL: config.baseURL, profiles: profiles)
            case .lidarr:
                fresh = Self.unify(try await LidarrClient(config: config).fetchAllArtists(), baseURL: config.baseURL, profiles: profiles)
            case .whisparr:
                fresh = Self.unify(try await WhisparrClient(config: config).fetchAllMovies(), baseURL: config.baseURL, profiles: profiles)
            }
            entries[source] = fresh
            fetchedAt[source] = Date()
        } catch {
            // Keep any stale cache on screen; the flag only surfaces an error
            // state when there's nothing at all to show.
            loadFailed.insert(source)
        }
    }

    // MARK: - Unify

    private static func state(monitored: Bool?, complete: Bool, partial: Bool, available: Bool = true) -> LibraryEntry.FileState {
        guard monitored ?? false else { return .unmonitored }
        if complete { return .complete }
        if partial { return .partial }
        return available ? .missing : .notAvailable
    }

    private static func unify(_ records: [RadarrLibraryRecord], baseURL: String, profiles: [Int: String]) -> [LibraryEntry] {
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
                ratingImdb: r.ratings?.imdb?.value, ratingTmdb: r.ratings?.tmdb?.value, ratingTvdb: nil,
                ratingRt: r.ratings?.rottenTomatoes?.value,
                ratingMetacritic: r.ratings?.metacritic?.value,
                releaseStatus: r.status,
                overview: r.overview
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
                ratingImdb: nil, ratingTmdb: nil, ratingTvdb: r.ratings?.value,
                releaseStatus: r.status,
                overview: r.overview
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
                ratingImdb: nil, ratingTmdb: nil, ratingTvdb: nil,
                releaseStatus: nil
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
                ratingImdb: nil, ratingTmdb: nil, ratingTvdb: nil,
                releaseStatus: r.status
            )
        }
    }
}
