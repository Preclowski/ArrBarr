import Foundation
import MediaKit

// MARK: - Radarr movie detail

// MARK: - Sonarr series detail

nonisolated public struct SonarrSeriesDetail: Codable, Sendable {
    public let id: Int
    /// TMDB series id — Sonarr v3 ships it; used for TMDB cast/credits.
    /// `var` (not `let`) with a default so it still DECODES while the
    /// memberwise init stays optional for demo mocks.
    var tmdbId: Int? = nil
    /// TVDB series id. Sonarr always ships this (it keys on TVDB); it's the
    /// fallback for resolving TMDB cast when `tmdbId` is absent — TMDB's
    /// `/find?external_source=tvdb_id` maps it to the tmdb tv id.
    var tvdbId: Int? = nil
    let title: String
    let year: Int?
    let overview: String?
    let genres: [String]?
    let runtime: Int?
    let ratings: SonarrDetailRatings?
    let network: String?
    /// Age rating ("TV-MA", "16"). Sonarr ships it on `/series/{id}`; the
    /// episode hero shows the series' one, since an episode has none of its own.
    var certification: String? = nil
    let status: String?
    let images: [ArrImage]?
    let titleSlug: String?
    /// `var` so a monitor toggle can write the flipped season flag back
    /// in place (optimistic update) without refetching the series.
    var seasons: [SonarrSeasonInfo]?
    let firstAired: String?
    /// See `ArrMovie.monitored`.
    var monitored: Bool? = nil
    /// See `ArrMovie.qualityProfileId`.
    var qualityProfileId: Int? = nil
}

nonisolated public struct SonarrDetailRatings: Codable, Sendable {
    let value: Double?
    let votes: Int?
}

nonisolated public struct SonarrSeasonInfo: Codable, Sendable {
    let seasonNumber: Int
    /// `var` for the optimistic in-place write from the monitor toggle.
    var monitored: Bool?
    let statistics: SonarrSeasonStats?
}

nonisolated public struct SonarrSeasonStats: Codable, Sendable {
    let episodeFileCount: Int?
    let episodeCount: Int?
    let totalEpisodeCount: Int?
    let sizeOnDisk: Int64?
    let percentOfEpisodes: Double?
}

nonisolated public struct SonarrEpisodeDetail: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    let seasonNumber: Int?
    let episodeNumber: Int?
    let title: String?
    let overview: String?
    let airDateUtc: String?
    let hasFile: Bool?
    /// `var` for the optimistic in-place write from the monitor toggle.
    var monitored: Bool?
    let runtime: Int?
    /// Sonarr's link to the episode-file record; non-nil exactly when
    /// `hasFile == true`. Lets the detail view fetch the full file
    /// payload (quality / size / customFormats) on demand.
    let episodeFileId: Int?
}

// MARK: - Lidarr album detail

nonisolated public struct LidarrAlbumDetail: Codable, Sendable {
    public let id: Int
    let title: String
    let overview: String?
    let releaseDate: String?
    let genres: [String]?
    let ratings: LidarrDetailRatings?
    let images: [ArrImage]?
    let artist: LidarrArtist?
    let foreignAlbumId: String?
    let albumType: String?
    let duration: Int?
    let statistics: LidarrAlbumStats?
    /// See `ArrMovie.monitored`.
    var monitored: Bool? = nil
    /// See `ArrMovie.qualityProfileId`.
    var qualityProfileId: Int? = nil
}

nonisolated public struct LidarrDetailRatings: Codable, Sendable {
    let value: Double?
    let votes: Int?
}

nonisolated public struct LidarrAlbumStats: Codable, Sendable {
    let trackCount: Int?
    let trackFileCount: Int?
    let totalTrackCount: Int?
    let sizeOnDisk: Int64?
}

/// Slim album record returned by `/api/v1/album?artistId=N`. Used by the
/// chat `lidarr_get_artist_albums` tool — keeps the response compact
/// when an artist has dozens of releases.
nonisolated public struct LidarrAlbumListRecord: Codable, Identifiable, Sendable {
    public let id: Int
    let title: String
    let albumType: String?
    let releaseDate: String?
    let monitored: Bool?
    let statistics: LidarrAlbumStats?
    /// Cover art for the artist view's album rows. Absent from the chat
    /// tool's JSON payload (it re-encodes its own slim shape).
    let images: [ArrImage]?
}

/// `/api/v1/artist/{id}` — the artist-level record behind `LidarrArtistView`.
/// Lidarr's library entity is the artist (albums hang off it), which is why
/// search results and the add flow land here rather than on an album.
nonisolated public struct LidarrArtistDetail: Codable, Sendable {
    public let id: Int
    let artistName: String
    let overview: String?
    let genres: [String]?
    let images: [ArrImage]?
    let foreignArtistId: String?
    let statistics: LidarrLibraryStatistics?
    let ratings: LidarrDetailRatings?
    /// `var` so the artist surface can flip it optimistically (and the demo
    /// fixture layer can overwrite it) — same as the movie/series details.
    public var monitored: Bool?
}

nonisolated public struct LidarrTrackDetail: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    let trackNumber: String?
    let absoluteTrackNumber: Int?
    let title: String?
    let duration: Int?
    let mediumNumber: Int?
    let hasFile: Bool?
    /// Joins the track to its `/trackfile` record (quality / size / formats)
    /// in the track detail view. nil when no file is on disk.
    let trackFileId: Int?
}
