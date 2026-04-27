import Foundation

actor SonarrClient {
    private let config: ServiceConfig
    private let http = HTTPClient()

    init(config: ServiceConfig) {
        self.config = config
    }

    func fetchQueue() async throws -> [QueueItem] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }

        let url = try http.url(
            base: config.baseURL,
            path: "/api/v3/queue",
            query: [
                URLQueryItem(name: "pageSize", value: "1000"),
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

    func fetchCalendar() async throws -> [UpcomingItem] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 14, to: now)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]

        let url = try http.url(
            base: config.baseURL,
            path: "/api/v3/calendar",
            query: [
                URLQueryItem(name: "start", value: fmt.string(from: now)),
                URLQueryItem(name: "end", value: fmt.string(from: end)),
                URLQueryItem(name: "includeSeries", value: "true"),
                URLQueryItem(name: "unmonitored", value: "false"),
            ]
        )
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])

        let records: [SonarrCalendarRecord]
        do {
            records = try JSONDecoder().decode([SonarrCalendarRecord].self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }

        return records.compactMap { Self.unifyCalendar($0) }
    }

    private static func unifyCalendar(_ r: SonarrCalendarRecord) -> UpcomingItem? {
        guard let dateStr = r.airDateUtc, let date = parseArrDate(dateStr) else { return nil }

        let seriesTitle = r.series?.title ?? "Unknown"
        var subtitle: String?
        if let s = r.seasonNumber, let e = r.episodeNumber {
            let code = String(format: "S%02dE%02d", s, e)
            if let epTitle = r.title, !epTitle.isEmpty {
                subtitle = "\(code) · \(epTitle)"
            } else {
                subtitle = code
            }
        }

        return UpcomingItem(
            id: "sonarr-cal-\(r.id)",
            source: .sonarr,
            title: seriesTitle,
            subtitle: subtitle,
            airDate: date,
            releaseType: "Airing",
            hasFile: r.hasFile ?? false,
            overview: r.overview
        )
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
            quality: r.quality?.name,
            isUpgrade: r.episode?.hasFile ?? false,
            contentSlug: r.series?.titleSlug
        )
    }
}
