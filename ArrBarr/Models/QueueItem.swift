import Foundation

/// Ujednolicony rekord kolejki, niezależny od źródła (Radarr/Sonarr).
/// Łączy dane z *arr (tytuł, custom formats) z metadanymi z klienta pobierającego (progress, status).
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

    let id: String                  // stabilny: "\(source)-\(arrQueueId)"
    let source: Source
    let arrQueueId: Int             // id w /api/v3/queue rekordu *arr
    let downloadId: String?         // hash (qBit) lub nzo_id (SAB); nil = nie ma jeszcze
    let downloadProtocol: DownloadProtocol
    let downloadClient: String?     // nazwa klienta z *arr (np. "qBittorrent", "SABnzbd")

    let title: String               // tytuł filmu/serialu z odcinkiem
    let subtitle: String?           // np. "S04E12 · Episode title"
    let status: Status
    let progress: Double            // 0.0...1.0
    let sizeTotal: Int64            // bytes
    let sizeLeft: Int64             // bytes
    let timeLeft: String?           // sformatowany "1h 23m" jeśli jest

    let customFormats: [String]     // nazwy custom formatów
    let customFormatScore: Int      // sumaryczny score
    let quality: String?            // np. "WEBDL-1080p"

    var isPaused: Bool { status == .paused }
    var isCompleted: Bool { status == .completed }
}
