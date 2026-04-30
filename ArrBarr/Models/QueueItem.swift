import Foundation

struct QueueItem: Identifiable, Equatable {
    enum Source: String, CaseIterable { case radarr, sonarr, lidarr

        var displayName: String {
            switch self {
            case .radarr: return "Radarr"
            case .sonarr: return "Sonarr"
            case .lidarr: return "Lidarr"
            }
        }

        var symbol: String {
            switch self {
            case .radarr: return "film"
            case .sonarr: return "tv"
            case .lidarr: return "music.note"
            }
        }
    }
    enum DownloadProtocol: String { case usenet, torrent, unknown }
    enum Status: String {
        case downloading, paused, queued, importing, completed, warning, failed, unknown

        var displayName: String {
            switch self {
            case .downloading: return "Downloading"
            case .paused: return "Paused"
            case .queued: return "Queued"
            case .importing: return "Importing"
            case .completed: return "Completed"
            case .warning: return "Warning"
            case .failed: return "Failed"
            case .unknown: return "Unknown"
            }
        }
    }

    let id: String
    let source: Source
    let arrQueueId: Int
    let downloadId: String?
    let downloadProtocol: DownloadProtocol
    let downloadClient: String?
    let indexer: String?

    let title: String
    let subtitle: String?
    let releaseName: String?
    var status: Status
    let progress: Double
    let sizeTotal: Int64
    let sizeLeft: Int64
    let timeLeft: String?

    let customFormats: [String]
    let customFormatScore: Int
    let quality: String?
    let isUpgrade: Bool
    let existingCustomFormats: [String]
    let existingCustomFormatScore: Int?
    let existingQuality: String?
    let existingSize: Int64?
    let existingFileName: String?
    let contentSlug: String?

    let posterURL: URL?
    let posterRequiresAuth: Bool

    init(
        id: String, source: Source, arrQueueId: Int,
        downloadId: String?, downloadProtocol: DownloadProtocol,
        downloadClient: String?, indexer: String? = nil,
        title: String, subtitle: String?, releaseName: String? = nil,
        status: Status, progress: Double, sizeTotal: Int64,
        sizeLeft: Int64, timeLeft: String?,
        customFormats: [String], customFormatScore: Int,
        quality: String?, isUpgrade: Bool,
        existingCustomFormats: [String] = [], existingCustomFormatScore: Int? = nil, existingQuality: String? = nil,
        existingSize: Int64? = nil, existingFileName: String? = nil,
        contentSlug: String?,
        posterURL: URL? = nil, posterRequiresAuth: Bool = false
    ) {
        self.id = id; self.source = source; self.arrQueueId = arrQueueId
        self.downloadId = downloadId; self.downloadProtocol = downloadProtocol
        self.downloadClient = downloadClient; self.indexer = indexer
        self.title = title; self.subtitle = subtitle; self.releaseName = releaseName
        self.status = status; self.progress = progress; self.sizeTotal = sizeTotal
        self.sizeLeft = sizeLeft; self.timeLeft = timeLeft
        self.customFormats = customFormats; self.customFormatScore = customFormatScore
        self.quality = quality; self.isUpgrade = isUpgrade; self.contentSlug = contentSlug
        self.existingCustomFormats = existingCustomFormats
        self.existingCustomFormatScore = existingCustomFormatScore
        self.existingQuality = existingQuality
        self.existingSize = existingSize
        self.existingFileName = existingFileName
        self.posterURL = posterURL; self.posterRequiresAuth = posterRequiresAuth
    }

    var isPaused: Bool { status == .paused }
    var isCompleted: Bool { status == .completed }
}
