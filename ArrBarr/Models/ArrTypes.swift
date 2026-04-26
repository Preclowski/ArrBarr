import Foundation

// MARK: - Wspólne typy Radarr/Sonarr v3

/// Strona zwrócona przez /api/v3/queue.
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

// MARK: - Radarr

struct RadarrQueueRecord: Decodable {
    let id: Int
    let movieId: Int?
    let title: String?              // np. tytuł release'u
    let status: String?
    let trackedDownloadStatus: String?
    let trackedDownloadState: String?
    let downloadId: String?
    let downloadClient: String?
    let `protocol`: String?
    let size: Double?               // Radarr zwraca double (bytes)
    let sizeleft: Double?
    let timeleft: String?           // ISO 8601 duration np. "00:23:45"
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
}

struct SonarrEpisode: Decodable {
    let id: Int
    let seasonNumber: Int?
    let episodeNumber: Int?
    let title: String?
}
