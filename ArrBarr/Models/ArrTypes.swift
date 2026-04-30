import Foundation

// MARK: - Shared Radarr/Sonarr v3 types
struct ArrQueuePage<Record: Decodable>: Decodable {
    let page: Int
    let pageSize: Int
    let totalRecords: Int
    let records: [Record]
}

struct ArrCustomFormat: Decodable, Equatable {
    let id: Int
    let name: String
}

struct ArrQuality: Decodable {
    let quality: ArrQualityName?
    struct ArrQualityName: Decodable { let name: String? }
    var name: String? { quality?.name }
}

struct ArrImage: Decodable, Equatable {
    let coverType: String?
    let url: String?
    let remoteUrl: String?
}

// MARK: - Radarr

struct RadarrQueueRecord: Decodable {
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

struct RadarrMovie: Decodable {
    let id: Int
    let title: String
    let year: Int?
    let originalTitle: String?
    let hasFile: Bool?
    let titleSlug: String?
    let images: [ArrImage]?
    let movieFile: ArrFile?
}

struct ArrFile: Decodable {
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let size: Int64?
    let relativePath: String?
}

struct RadarrMovieFile: Decodable {
    let id: Int
    let movieId: Int?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let size: Int64?
    let relativePath: String?
}

// MARK: - Sonarr

struct SonarrQueueRecord: Decodable {
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

struct SonarrSeries: Decodable {
    let id: Int
    let title: String
    let year: Int?
    let titleSlug: String?
    let images: [ArrImage]?
}

struct SonarrEpisode: Decodable {
    let id: Int
    let seasonNumber: Int?
    let episodeNumber: Int?
    let title: String?
    let hasFile: Bool?
    let episodeFileId: Int?
}

struct SonarrEpisodeFile: Decodable {
    let id: Int
    let seriesId: Int?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let size: Int64?
    let relativePath: String?
}

// MARK: - Lidarr

struct LidarrQueueRecord: Decodable {
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

struct LidarrArtist: Decodable {
    let id: Int
    let artistName: String
    let foreignArtistId: String?
    let images: [ArrImage]?
}

struct LidarrAlbum: Decodable {
    let id: Int
    let title: String
    let releaseDate: String?
    let foreignAlbumId: String?
    let artist: LidarrArtist?
    let images: [ArrImage]?
}

struct LidarrCalendarRecord: Decodable {
    let id: Int
    let title: String
    let releaseDate: String?
    let foreignAlbumId: String?
    let overview: String?
    let artist: LidarrArtist?
    let images: [ArrImage]?
}

// MARK: - History

struct RadarrHistoryRecord: Decodable {
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

struct SonarrHistoryRecord: Decodable {
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

struct LidarrHistoryRecord: Decodable {
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

struct ArrHealthRecord: Decodable, Equatable {
    let source: String?
    let type: String?
    let message: String?
    let wikiUrl: String?
}

// MARK: - Calendar

struct RadarrCalendarRecord: Decodable {
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

struct SonarrCalendarRecord: Decodable {
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
