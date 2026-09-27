import Foundation
import MediaKit

// MARK: - Radarr movie detail

// MARK: - Sonarr series detail

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
