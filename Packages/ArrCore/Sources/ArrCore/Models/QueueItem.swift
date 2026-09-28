import Foundation

nonisolated public struct QueueItem: Identifiable, Equatable, Hashable, Sendable {
    nonisolated public enum Source: String, CaseIterable, Sendable, Codable { case radarr, sonarr, lidarr, whisparr

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
    /// Sonarr-only, so consumers needn't parse `subtitle`. nil for other arrs and unknown episodes.
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let episodeTitle: String?
    public let releaseName: String?
    public var status: Status
    /// `var` so `QueueAggregator` can overlay the download client's fresher live value.
    public var progress: Double
    public let sizeTotal: Int64
    public let sizeLeft: Int64
    public let timeLeft: String?
    /// Not every client reports one (SABnzbd only for the whole queue), so `progressRatePerSecond` falls back to the arr's ETA.
    public var downloadSpeed: Int64? = nil


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
    public let entityId: Int?

    public let posterURL: URL?
    public let posterRequiresAuth: Bool
    /// Resolved at composition time: a row carries no provider ids of its own.
    public let watched: Bool

    /// One merged "Title — Message" line each; the arr only attaches messages on `warning` / `failed`.
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
        downloadSpeed: Int64? = nil,
        customFormats: [String], customFormatScore: Int,
        quality: String?, releaseGroup: String? = nil, isUpgrade: Bool,
        existingCustomFormats: [String] = [], existingCustomFormatScore: Int? = nil, existingQuality: String? = nil,
        existingSize: Int64? = nil, existingFileName: String? = nil,
        contentSlug: String?,
        entityId: Int? = nil,
        posterURL: URL? = nil, posterRequiresAuth: Bool = false,
        watched: Bool = false,
        statusMessages: [String] = []
    ) {
        self.id = id; self.source = source; self.arrQueueId = arrQueueId
        self.downloadId = downloadId; self.downloadProtocol = downloadProtocol
        self.downloadClient = downloadClient; self.indexer = indexer
        self.title = title; self.subtitle = subtitle; self.releaseName = releaseName
        self.seasonNumber = seasonNumber; self.episodeNumber = episodeNumber; self.episodeTitle = episodeTitle
        self.status = status; self.progress = progress; self.sizeTotal = sizeTotal
        self.sizeLeft = sizeLeft; self.timeLeft = timeLeft
        self.downloadSpeed = downloadSpeed
        self.customFormats = customFormats; self.customFormatScore = customFormatScore
        self.quality = quality; self.releaseGroup = releaseGroup
        self.isUpgrade = isUpgrade; self.contentSlug = contentSlug; self.entityId = entityId
        self.existingCustomFormats = existingCustomFormats
        self.existingCustomFormatScore = existingCustomFormatScore
        self.existingQuality = existingQuality
        self.existingSize = existingSize
        self.existingFileName = existingFileName
        self.posterURL = posterURL; self.posterRequiresAuth = posterRequiresAuth
        self.watched = watched
        self.statusMessages = statusMessages
    }

    public var isPaused: Bool { status == .paused }

    var isPendingRelease: Bool { downloadId?.isEmpty ?? true }

    /// On grab the arr drops the pending row and tracks the download under a new queue id,
    /// so the entity and episode are all the two rows share.
    var handoffKey: String? {
        guard let entityId else { return nil }
        return "\(source.rawValue)|\(entityId)|\(seasonNumber ?? -1)|\(episodeNumber ?? -1)"
    }

    /// Stable across a delay-profile grab's queue-id change: the download id, else the episode/movie coordinates.
    var hideKey: String {
        if let downloadId, !downloadId.isEmpty {
            return "\(source.rawValue)|dl|\(downloadId.lowercased())"
        }
        if let handoffKey { return "\(source.rawValue)|ep|\(handoffKey)" }
        return "\(source.rawValue)|id|\(id)"
    }

    /// A pending row hidden by coordinates stays hidden once it becomes a real download.
    var hideMatchKeys: [String] {
        var keys = [hideKey]
        if let handoffKey { keys.append("\(source.rawValue)|ep|\(handoffKey)") }
        return keys
    }

    func succeeds(_ pending: QueueItem) -> Bool {
        guard pending.isPendingRelease, !isPendingRelease, let key = handoffKey else { return false }
        return key == pending.handoffKey
    }

    /// An arr can flag an upgrade yet ship none of the `existing*` fields; every diff surface must agree.
    public var hasExistingFileMetadata: Bool {
        (existingQuality.map { !$0.isEmpty } ?? false)
            || (existingSize ?? 0) > 0
            || (existingCustomFormatScore ?? 0) != 0
    }

    /// Detail auto-drills to an episode only when `episodeNumber` is set; season packs open the SEASON.
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
            watched: watched,
            statusMessages: statusMessages
        )
    }
}
