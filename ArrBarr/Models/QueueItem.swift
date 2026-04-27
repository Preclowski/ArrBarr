import Foundation

struct QueueItem: Identifiable, Equatable {
    enum Source: String { case radarr, sonarr }
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

    var isPaused: Bool { status == .paused }
    var isCompleted: Bool { status == .completed }
}
