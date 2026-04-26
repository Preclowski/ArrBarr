import Foundation

actor SonarrClient {
    private let config: ServiceConfig
    private let http = HTTPClient()

    init(config: ServiceConfig) {
        self.config = config
    }

    func fetchQueue() async throws -> [QueueItem] {
        guard config.isConfigured, !config.apiKey.isEmpty else { throw HTTPError.notConfigured }

        let url = try http.url(
            base: config.baseURL,
            path: "/api/v3/queue",
            query: [
                URLQueryItem(name: "pageSize", value: "200"),
                URLQueryItem(name: "includeSeries", value: "true"),
                URLQueryItem(name: "includeEpisode", value: "true"),
                URLQueryItem(name: "includeUnknownSeriesItems", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])

        let page: ArrQueuePage<SonarrQueueRecord>
        do {
            page = try JSONDecoder().decode(ArrQueuePage<SonarrQueueRecord>.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }

        return page.records.map { Self.unify($0) }
    }

    private static func unify(_ r: SonarrQueueRecord) -> QueueItem {
        let total = Int64(r.size ?? 0)
        let left = Int64(r.sizeleft ?? 0)
        let progress: Double
        if total > 0 {
            progress = max(0, min(1, 1.0 - Double(left) / Double(total)))
        } else {
            progress = 0
        }

        let title: String
        let subtitle: String?
        if let s = r.series {
            title = s.title
            if let ep = r.episode, let season = ep.seasonNumber, let number = ep.episodeNumber {
                let code = String(format: "S%02dE%02d", season, number)
                if let epTitle = ep.title, !epTitle.isEmpty {
                    subtitle = "\(code) · \(epTitle)"
                } else {
                    subtitle = code
                }
            } else {
                subtitle = nil
            }
        } else {
            title = r.title ?? "Unknown"
            subtitle = nil
        }

        return QueueItem(
            id: "sonarr-\(r.id)",
            source: .sonarr,
            arrQueueId: r.id,
            downloadId: r.downloadId,
            downloadProtocol: parseProtocol(r.protocol),
            downloadClient: r.downloadClient,
            title: title,
            subtitle: subtitle,
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
