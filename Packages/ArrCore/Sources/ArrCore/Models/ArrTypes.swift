import Foundation

// MARK: - Shared Radarr/Sonarr v3 types
public struct ArrQueuePage<Record: Decodable>: Decodable {
    let page: Int
    let pageSize: Int
    let totalRecords: Int
    let records: [Record]
}

public struct ArrCustomFormat: Decodable, Equatable {
    let id: Int
    let name: String
}

public struct ArrQuality: Decodable {
    let quality: ArrQualityName?
    struct ArrQualityName: Decodable { let name: String? }
    var name: String? { quality?.name }
}

public struct ArrImage: Decodable, Equatable, Sendable {
    let coverType: String?
    let url: String?
    let remoteUrl: String?
}

// MARK: - Radarr

public struct RadarrQueueRecord: Decodable {
    let id: Int
    let movieId: Int?
    let title: String?
    let status: String?
    let trackedDownloadStatus: String?
    let trackedDownloadState: String?
    let downloadId: String?
    let downloadClient: String?
    let indexer: String?
    let `protocol`: String?
    let size: Double?
    let sizeleft: Double?
    let timeleft: String?
    let estimatedCompletionTime: String?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let movie: RadarrMovie?
}

public struct RadarrMovie: Decodable {
    let id: Int
    let title: String
    let year: Int?
    let originalTitle: String?
    let hasFile: Bool?
    let titleSlug: String?
    let images: [ArrImage]?
    let movieFile: ArrFile?
}

public struct ArrFile: Decodable {
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let size: Int64?
    let relativePath: String?
}

public struct RadarrMovieFile: Decodable {
    let id: Int
    let movieId: Int?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let size: Int64?
    let relativePath: String?
}

// MARK: - Sonarr

public struct SonarrQueueRecord: Decodable {
    let id: Int
    let seriesId: Int?
    let episodeId: Int?
    let seasonNumber: Int?
    let title: String?
    let status: String?
    let trackedDownloadStatus: String?
    let trackedDownloadState: String?
    let downloadId: String?
    let downloadClient: String?
    let indexer: String?
    let `protocol`: String?
    let size: Double?
    let sizeleft: Double?
    let timeleft: String?
    let estimatedCompletionTime: String?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let series: SonarrSeries?
    let episode: SonarrEpisode?
}

public struct SonarrSeries: Decodable {
    let id: Int
    let title: String
    let year: Int?
    let titleSlug: String?
    let images: [ArrImage]?
}

public struct SonarrEpisode: Decodable {
    let id: Int
    let seasonNumber: Int?
    let episodeNumber: Int?
    let title: String?
    let hasFile: Bool?
    let episodeFileId: Int?
}

public struct SonarrEpisodeFile: Decodable {
    let id: Int
    let seriesId: Int?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let size: Int64?
    let relativePath: String?
}

// MARK: - Lidarr

public struct LidarrQueueRecord: Decodable {
    let id: Int
    let artistId: Int?
    let albumId: Int?
    let title: String?
    let status: String?
    let trackedDownloadStatus: String?
    let trackedDownloadState: String?
    let downloadId: String?
    let downloadClient: String?
    let indexer: String?
    let `protocol`: String?
    let size: Double?
    let sizeleft: Double?
    let timeleft: String?
    let estimatedCompletionTime: String?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let artist: LidarrArtist?
    let album: LidarrAlbum?
}

public struct LidarrArtist: Decodable {
    let id: Int
    let artistName: String
    let foreignArtistId: String?
    let images: [ArrImage]?
}

public struct LidarrAlbum: Decodable {
    let id: Int
    let title: String
    let releaseDate: String?
    let foreignAlbumId: String?
    let artist: LidarrArtist?
    let images: [ArrImage]?
}

public struct LidarrCalendarRecord: Decodable {
    let id: Int
    let title: String
    let releaseDate: String?
    let foreignAlbumId: String?
    let overview: String?
    let artist: LidarrArtist?
    let images: [ArrImage]?
}

// MARK: - History

public struct RadarrHistoryRecord: Decodable {
    let id: Int
    let movieId: Int?
    let sourceTitle: String?
    let date: String?
    let eventType: String?
    let quality: ArrQuality?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let movie: RadarrMovie?
}

public struct SonarrHistoryRecord: Decodable {
    let id: Int
    let episodeId: Int?
    let seriesId: Int?
    let sourceTitle: String?
    let date: String?
    let eventType: String?
    let quality: ArrQuality?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let series: SonarrSeries?
    let episode: SonarrEpisode?
}

public struct LidarrHistoryRecord: Decodable {
    let id: Int
    let albumId: Int?
    let artistId: Int?
    let sourceTitle: String?
    let date: String?
    let eventType: String?
    let quality: ArrQuality?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let artist: LidarrArtist?
    let album: LidarrAlbum?
}

// MARK: - Health

public struct ArrHealthRecord: Decodable, Equatable {
    let source: String?
    let type: String?
    let message: String?
    let wikiUrl: String?
}

// MARK: - Calendar

public struct RadarrCalendarRecord: Decodable {
    let id: Int
    let title: String
    let year: Int?
    let digitalRelease: String?
    let physicalRelease: String?
    let inCinemas: String?
    let hasFile: Bool?
    let overview: String?
    let images: [ArrImage]?
    let titleSlug: String?
}

public struct SonarrCalendarRecord: Decodable {
    let id: Int
    let seriesId: Int?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let title: String?
    let airDateUtc: String?
    let hasFile: Bool?
    let overview: String?
    let series: SonarrSeries?
}

// MARK: - Search Lookup

public struct RadarrLookupRecord: Decodable {
    let tmdbId: Int?
    let title: String
    let year: Int?
    let overview: String?
    let runtime: Int?
    let ratings: RadarrLookupRatings?
    let images: [ArrImage]?
    let genres: [String]?
    let certification: String?
    let studio: String?
    let status: String?
}

public struct RadarrLookupRatings: Decodable {
    let tmdb: RadarrLookupRatingValue?
    let imdb: RadarrLookupRatingValue?
    let metacritic: RadarrLookupRatingValue?
    let rottenTomatoes: RadarrLookupRatingValue?
}
public struct RadarrLookupRatingValue: Decodable {
    let value: Double?
}

public struct SonarrLookupRecord: Decodable {
    let tvdbId: Int?
    let title: String
    let year: Int?
    let overview: String?
    let ratings: SonarrLookupRatings?
    let images: [ArrImage]?
    let statistics: SonarrLookupStats?
    let genres: [String]?
    let network: String?
    let runtime: Int?
    let status: String?
}

public struct SonarrLookupRatings: Decodable {
    let value: Double?
}

public struct SonarrLookupStats: Decodable {
    let seasonCount: Int?
}

// MARK: - Lidarr library / lookup types

public struct LidarrLibraryRecord: Decodable, Sendable, Equatable {
    public let id: Int?
    public let foreignArtistId: String?
    public let artistName: String?
    public let monitored: Bool?
    public let images: [ArrImage]?
    public let statistics: LidarrLibraryStatistics?
}
public struct LidarrLibraryStatistics: Decodable, Sendable, Equatable {
    public let albumCount: Int?
    public let trackCount: Int?
    public let trackFileCount: Int?
}

public struct LidarrLookupRecord: Decodable {
    public let foreignArtistId: String?
    public let artistName: String
    public let disambiguation: String?
    public let overview: String?
    public let images: [ArrImage]?
    public let ratings: LidarrLookupRatings?
    public let genres: [String]?
}
public struct LidarrLookupRatings: Decodable {
    public let value: Double?
}

public struct MetadataProfile: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
}

// Used to fetch existing library ids and list library contents
public struct RadarrLibraryRecord: Decodable, Sendable, Equatable {
    let id: Int?
    let tmdbId: Int?
    let title: String?
    let year: Int?
    let hasFile: Bool?
    let monitored: Bool?
    let images: [ArrImage]?
}
public struct SonarrLibraryRecord: Decodable, Sendable, Equatable {
    let id: Int?
    let tvdbId: Int?
    let title: String?
    let year: Int?
    let status: String?
    let monitored: Bool?
    let statistics: SonarrLibraryStatistics?
    let images: [ArrImage]?
}
public struct SonarrLibraryStatistics: Decodable, Sendable, Equatable {
    let episodeCount: Int?
    let episodeFileCount: Int?
    let seasonCount: Int?
}

// MARK: - ArrImage helpers

public extension Array where Element == ArrImage {
    /// Resolves a poster URL from an Arr images array.
    /// Prefers `remoteUrl` (TMDB / MusicBrainz / etc., no auth) over the local server URL.
    /// - Parameter baseURL: The arr server base URL (used when only a local path is available).
    /// - Parameter coverTypes: Cover type names to match, in priority order (default: `["poster"]`).
    /// - Returns: the URL plus whether it requires the X-Api-Key header.
    func posterURL(baseURL: String, coverTypes: [String] = ["poster"]) -> (URL?, Bool) {
        let normalized = coverTypes.map { $0.lowercased() }
        let match = first { img in
            guard let type = img.coverType?.lowercased() else { return false }
            return normalized.contains(type)
        }
        guard let match else { return (nil, false) }

        if let remote = match.remoteUrl, let url = URL(string: remote) {
            return (url, false)
        }
        if let path = match.url, let base = URL(string: baseURL) {
            // Some Arrs return absolute, some relative. Strip query (cache-busting hash) for stable cache keys.
            if let abs = URL(string: path), abs.scheme != nil {
                return (abs, true)
            }
            let trimmed = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
            let composed = URL(string: trimmed, relativeTo: base)?.absoluteURL
            return (composed, true)
        }
        return (nil, false)
    }
}
