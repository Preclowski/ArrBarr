import Foundation

// MARK: - Radarr movie detail

public struct RadarrMovieDetail: Decodable {
    public let id: Int
    /// TMDB movie id — used to fetch cast/credits (TMDB-only data). `var`
    /// (not `let`) with a default so it still DECODES from JSON while the
    /// memberwise init stays optional for demo mocks — a `let … = nil` would
    /// be silently dropped from Decodable's synthesized keys.
    var tmdbId: Int? = nil
    let title: String
    let year: Int?
    let overview: String?
    let runtime: Int?
    let genres: [String]?
    let ratings: RadarrDetailRatings?
    let images: [ArrImage]?
    let studio: String?
    let certification: String?
    let titleSlug: String?
    let movieFile: ArrFile?
    let inCinemas: String?
    let status: String?
    /// Radarr's monitored flag. `var … = nil` for the same reason as
    /// `tmdbId` above (decodes from JSON, stays optional in the
    /// memberwise init) — and `nil` is load-bearing here: "the field
    /// didn't decode" hides the monitor toggle instead of rendering a
    /// bookmark that lies about state.
    var monitored: Bool? = nil
    /// Assigned quality profile — resolved to a name for the hero's chip.
    var qualityProfileId: Int? = nil
}

public struct RadarrDetailRatings: Decodable {
    let imdb: RadarrRatingValue?
    let tmdb: RadarrRatingValue?
    let metacritic: RadarrRatingValue?
    let rottenTomatoes: RadarrRatingValue?
}

public struct RadarrRatingValue: Decodable {
    let value: Double?
    let votes: Int?
}

// MARK: - Sonarr series detail

public struct SonarrSeriesDetail: Decodable {
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
    let status: String?
    let images: [ArrImage]?
    let titleSlug: String?
    /// `var` so a monitor toggle can write the flipped season flag back
    /// in place (optimistic update) without refetching the series.
    var seasons: [SonarrSeasonInfo]?
    let firstAired: String?
    /// See `RadarrMovieDetail.monitored`.
    var monitored: Bool? = nil
    /// See `RadarrMovieDetail.qualityProfileId`.
    var qualityProfileId: Int? = nil
}

public struct SonarrDetailRatings: Decodable {
    let value: Double?
    let votes: Int?
}

public struct SonarrSeasonInfo: Decodable {
    let seasonNumber: Int
    /// `var` for the optimistic in-place write from the monitor toggle.
    var monitored: Bool?
    let statistics: SonarrSeasonStats?
}

public struct SonarrSeasonStats: Decodable {
    let episodeFileCount: Int?
    let episodeCount: Int?
    let totalEpisodeCount: Int?
    let sizeOnDisk: Int64?
    let percentOfEpisodes: Double?
}

public struct SonarrEpisodeDetail: Decodable, Identifiable, Hashable {
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

public struct LidarrAlbumDetail: Decodable {
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
    /// See `RadarrMovieDetail.monitored`.
    var monitored: Bool? = nil
    /// See `RadarrMovieDetail.qualityProfileId`.
    var qualityProfileId: Int? = nil
}

public struct LidarrDetailRatings: Decodable {
    let value: Double?
    let votes: Int?
}

public struct LidarrAlbumStats: Decodable, Sendable {
    let trackCount: Int?
    let trackFileCount: Int?
    let totalTrackCount: Int?
    let sizeOnDisk: Int64?
}

/// Slim album record returned by `/api/v1/album?artistId=N`. Used by the
/// chat `lidarr_get_artist_albums` tool — keeps the response compact
/// when an artist has dozens of releases.
public struct LidarrAlbumListRecord: Decodable, Identifiable, Sendable {
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
public struct LidarrArtistDetail: Decodable {
    public let id: Int
    let artistName: String
    let overview: String?
    let genres: [String]?
    let images: [ArrImage]?
    let foreignArtistId: String?
    let statistics: LidarrLibraryStatistics?
    let ratings: LidarrDetailRatings?
    let monitored: Bool?
}

public struct LidarrTrackDetail: Decodable, Identifiable, Hashable {
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
