import Foundation

public struct QueueItem: Identifiable, Equatable, Hashable, Sendable {
    public enum Source: String, CaseIterable, Sendable { case radarr, sonarr, lidarr, whisparr

        public var displayName: String {
            switch self {
            case .radarr: return "Radarr"
            case .sonarr: return "Sonarr"
            case .lidarr: return "Lidarr"
            case .whisparr: return "Whisparr"
            }
        }

        public var symbol: String {
            switch self {
            case .radarr: return "film"
            case .sonarr: return "tv"
            case .lidarr: return "music.note"
            case .whisparr: return "flame"
            }
        }
    }
    public enum DownloadProtocol: String, Sendable { case usenet, torrent, unknown }
    public enum Status: String, Sendable {
        case downloading, paused, queued, importing, completed, warning, failed, unknown

        public var displayName: String {
            switch self {
            case .downloading: return String(localized: "queue.downloading.button", bundle: .module)
            case .paused:      return String(localized: "queue.paused.button", bundle: .module)
            case .queued:      return String(localized: "queue.queued.button", bundle: .module)
            case .importing:   return String(localized: "queue.importing.button", bundle: .module)
            case .completed:   return String(localized: "queue.completed.button", bundle: .module)
            case .warning:     return String(localized: "queue.warning.button", bundle: .module)
            case .failed:      return String(localized: "history.failed.button", bundle: .module)
            case .unknown:     return String(localized: "queue.unknown.button", bundle: .module)
            }
        }
    }

    public let id: String
    public let source: Source
    public let arrQueueId: Int
    public let downloadId: String?
    public let downloadProtocol: DownloadProtocol
    public let downloadClient: String?
    public let indexer: String?

    public let title: String
    public let subtitle: String?
    /// Sonarr-only: structured episode coordinates so consumers don't have
    /// to regex-parse `subtitle` to know which episode the row represents.
    /// nil for Radarr / Lidarr / unknown-episode Sonarr rows.
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let episodeTitle: String?
    public let releaseName: String?
    public var status: Status
    public let progress: Double
    public let sizeTotal: Int64
    public let sizeLeft: Int64
    public let timeLeft: String?

    public let customFormats: [String]
    public let customFormatScore: Int
    public let quality: String?
    public let releaseGroup: String?
    public let isUpgrade: Bool
    public let existingCustomFormats: [String]
    public let existingCustomFormatScore: Int?
    public let existingQuality: String?
    public let existingSize: Int64?
    public let existingFileName: String?
    public let contentSlug: String?
    /// Underlying arr entity id — Radarr `movie.id`, Sonarr `series.id`,
    /// Lidarr `album.id`. Used to fetch detail views.
    public let entityId: Int?

    public let posterURL: URL?
    public let posterRequiresAuth: Bool

    /// Flattened user-facing warning lines from the arr's
    /// `statusMessages` payload. Populated only when status is
    /// `warning` / `failed` — those are the only times the arr
    /// attaches a message. Empty for healthy rows. Each string is one
    /// already-merged "Title — Message" line so the consuming view
    /// can just iterate and render.
    public let statusMessages: [String]

    public init(
        id: String, source: Source, arrQueueId: Int,
        downloadId: String?, downloadProtocol: DownloadProtocol,
        downloadClient: String?, indexer: String? = nil,
        title: String, subtitle: String?,
        seasonNumber: Int? = nil, episodeNumber: Int? = nil, episodeTitle: String? = nil,
        releaseName: String? = nil,
        status: Status, progress: Double, sizeTotal: Int64,
        sizeLeft: Int64, timeLeft: String?,
        customFormats: [String], customFormatScore: Int,
        quality: String?, releaseGroup: String? = nil, isUpgrade: Bool,
        existingCustomFormats: [String] = [], existingCustomFormatScore: Int? = nil, existingQuality: String? = nil,
        existingSize: Int64? = nil, existingFileName: String? = nil,
        contentSlug: String?,
        entityId: Int? = nil,
        posterURL: URL? = nil, posterRequiresAuth: Bool = false,
        statusMessages: [String] = []
    ) {
        self.id = id; self.source = source; self.arrQueueId = arrQueueId
        self.downloadId = downloadId; self.downloadProtocol = downloadProtocol
        self.downloadClient = downloadClient; self.indexer = indexer
        self.title = title; self.subtitle = subtitle; self.releaseName = releaseName
        self.seasonNumber = seasonNumber; self.episodeNumber = episodeNumber; self.episodeTitle = episodeTitle
        self.status = status; self.progress = progress; self.sizeTotal = sizeTotal
        self.sizeLeft = sizeLeft; self.timeLeft = timeLeft
        self.customFormats = customFormats; self.customFormatScore = customFormatScore
        self.quality = quality; self.releaseGroup = releaseGroup
        self.isUpgrade = isUpgrade; self.contentSlug = contentSlug; self.entityId = entityId
        self.existingCustomFormats = existingCustomFormats
        self.existingCustomFormatScore = existingCustomFormatScore
        self.existingQuality = existingQuality
        self.existingSize = existingSize
        self.existingFileName = existingFileName
        self.posterURL = posterURL; self.posterRequiresAuth = posterRequiresAuth
        self.statusMessages = statusMessages
    }

    public var isPaused: Bool { status == .paused }
    public var isCompleted: Bool { status == .completed }

    /// Copy with the episode coordinates cleared. A detail view auto-drills to
    /// a specific episode only when `episodeNumber` is set — season-pack rows
    /// pass this so the detail opens the SEASON instead.
    public func seasonContext() -> QueueItem {
        QueueItem(
            id: id, source: source, arrQueueId: arrQueueId,
            downloadId: downloadId, downloadProtocol: downloadProtocol,
            downloadClient: downloadClient, indexer: indexer,
            title: title, subtitle: subtitle,
            seasonNumber: seasonNumber, episodeNumber: nil, episodeTitle: episodeTitle,
            releaseName: releaseName,
            status: status, progress: progress, sizeTotal: sizeTotal,
            sizeLeft: sizeLeft, timeLeft: timeLeft,
            customFormats: customFormats, customFormatScore: customFormatScore,
            quality: quality, releaseGroup: releaseGroup, isUpgrade: isUpgrade,
            existingCustomFormats: existingCustomFormats,
            existingCustomFormatScore: existingCustomFormatScore,
            existingQuality: existingQuality, existingSize: existingSize,
            existingFileName: existingFileName,
            contentSlug: contentSlug, entityId: entityId,
            posterURL: posterURL, posterRequiresAuth: posterRequiresAuth,
            statusMessages: statusMessages
        )
    }
}
