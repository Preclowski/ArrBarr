import Foundation

actor RadarrClient {
    private let config: ServiceConfig
    private let http = HTTPClient()

    init(config: ServiceConfig) {
        self.config = config
    }

    /// Pobiera kolejkę z metadanymi filmu i custom formatami w jednym requeście.
    func fetchQueue() async throws -> [QueueItem] {
        guard config.isConfigured, !config.apiKey.isEmpty else { throw HTTPError.notConfigured }

        let url = try http.url(
            base: config.baseURL,
            path: "/api/v3/queue",
            query: [
                URLQueryItem(name: "pageSize", value: "200"),
                URLQueryItem(name: "includeMovie", value: "true"),
                URLQueryItem(name: "includeUnknownMovieItems", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])

        let page: ArrQueuePage<RadarrQueueRecord>
        do {
            page = try JSONDecoder().decode(ArrQueuePage<RadarrQueueRecord>.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }

        return page.records.map { Self.unify($0) }
    }

    private static func unify(_ r: RadarrQueueRecord) -> QueueItem {
        let total = Int64(r.size ?? 0)
        let left = Int64(r.sizeleft ?? 0)
        let progress: Double
        if total > 0 {
            progress = max(0, min(1, 1.0 - Double(left) / Double(total)))
        } else {
            progress = 0
        }

        let movieTitle: String
        if let m = r.movie {
            if let y = m.year { movieTitle = "\(m.title) (\(y))" } else { movieTitle = m.title }
        } else {
            movieTitle = r.title ?? "Unknown"
        }

        return QueueItem(
            id: "radarr-\(r.id)",
            source: .radarr,
            arrQueueId: r.id,
            downloadId: r.downloadId,
            downloadProtocol: parseProtocol(r.protocol),
            downloadClient: r.downloadClient,
            title: movieTitle,
            subtitle: nil,
            status: parseStatus(arrStatus: r.status, trackedState: r.trackedDownloadState),
            progress: progress,
            sizeTotal: total,
            sizeLeft: left,
            timeLeft: r.timeleft,
            customFormats: (r.customFormats ?? []).map(\.name),
            customFormatScore: r.customFormatScore ?? 0,
            quality: r.quality?.name
        )
    }
}

func parseProtocol(_ raw: String?) -> QueueItem.DownloadProtocol {
    switch raw?.lowercased() {
    case "usenet": return .usenet
    case "torrent": return .torrent
    default: return .unknown
    }
}

func parseStatus(arrStatus: String?, trackedState: String?) -> QueueItem.Status {
    // *arr używa trackedDownloadState dla bardziej precyzyjnego stanu
    if let tracked = trackedState?.lowercased() {
        switch tracked {
        case "downloading": return .downloading
        case "downloadfailed", "failedpending": return .failed
        case "imported", "importing", "importpending": return .completed
        default: break
        }
    }
    switch arrStatus?.lowercased() {
    case "downloading": return .downloading
    case "paused": return .paused
    case "queued", "delay": return .queued
    case "completed": return .completed
    case "warning": return .warning
    case "failed": return .failed
    default: return .unknown
    }
}
