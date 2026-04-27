import Foundation

struct QueueItem: Identifiable, Equatable {
    enum Source: String { case radarr, sonarr, lidarr }
    enum DownloadProtocol: String { case usenet, torrent, unknown }
    enum Status: String {
        case downloading, paused, queued, completed, warning, failed, unknown

        var displayName: String {
            switch self {
            case .downloading: return "Downloading"
            case .paused: return "Paused"
            case .queued: return "Queued"
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

    let title: String
    let subtitle: String?
    let status: Status
    let progress: Double
    let sizeTotal: Int64
    let sizeLeft: Int64
    let timeLeft: String?

    let customFormats: [String]
    let customFormatScore: Int
    let quality: String?
    let isUpgrade: Bool
    let contentSlug: String?

    let posterURL: URL?
    let posterRequiresAuth: Bool

    init(
        id: String, source: Source, arrQueueId: Int,
        downloadId: String?, downloadProtocol: DownloadProtocol,
        downloadClient: String?, title: String, subtitle: String?,
        status: Status, progress: Double, sizeTotal: Int64,
        sizeLeft: Int64, timeLeft: String?,
        customFormats: [String], customFormatScore: Int,
        quality: String?, isUpgrade: Bool, contentSlug: String?,
        posterURL: URL? = nil, posterRequiresAuth: Bool = false
    ) {
        self.id = id; self.source = source; self.arrQueueId = arrQueueId
        self.downloadId = downloadId; self.downloadProtocol = downloadProtocol
        self.downloadClient = downloadClient; self.title = title; self.subtitle = subtitle
        self.status = status; self.progress = progress; self.sizeTotal = sizeTotal
        self.sizeLeft = sizeLeft; self.timeLeft = timeLeft
        self.customFormats = customFormats; self.customFormatScore = customFormatScore
        self.quality = quality; self.isUpgrade = isUpgrade; self.contentSlug = contentSlug
        self.posterURL = posterURL; self.posterRequiresAuth = posterRequiresAuth
    }

    var isPaused: Bool { status == .paused }
    var isCompleted: Bool { status == .completed }
}
