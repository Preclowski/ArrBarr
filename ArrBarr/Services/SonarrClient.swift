import Foundation

actor SonarrClient {
    private let config: ServiceConfig
    private let http = HTTPClient()

    init(config: ServiceConfig) {
        self.config = config
    }

    func testConnection() async throws -> String {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "/api/v3/system/status")
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])
        struct Status: Decodable { let version: String? }
        let status = try? JSONDecoder().decode(Status.self, from: data)
        return status?.version.map { "Sonarr \($0)" } ?? "OK"
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

        let baseURL = config.baseURL
        let seriesIds = Set(page.records.compactMap { $0.series?.id ?? $0.seriesId })
        var fileMap: [Int: SonarrEpisodeFile] = [:]
        await withTaskGroup(of: [SonarrEpisodeFile].self) { group in
            for sid in seriesIds {
                group.addTask { (try? await self.fetchEpisodeFiles(seriesId: sid)) ?? [] }
            }
            for await files in group {
                for f in files { fileMap[f.id] = f }
            }
        }
        return page.records.map { Self.unify($0, baseURL: baseURL, fileMap: fileMap) }
    }

    private func fetchEpisodeFiles(seriesId: Int) async throws -> [SonarrEpisodeFile] {
        let url = try http.url(
            base: config.baseURL,
            path: "/api/v3/episodefile",
            query: [URLQueryItem(name: "seriesId", value: String(seriesId))]
        )
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])
        return (try? JSONDecoder().decode([SonarrEpisodeFile].self, from: data)) ?? []
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

        let baseURL = config.baseURL
        return records.compactMap { Self.unifyCalendar($0, baseURL: baseURL) }
    }

    func fetchHistory() async throws -> [HistoryItem] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "/api/v3/history",
            query: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pageSize", value: "50"),
                URLQueryItem(name: "sortKey", value: "date"),
                URLQueryItem(name: "sortDirection", value: "descending"),
                URLQueryItem(name: "includeSeries", value: "true"),
                URLQueryItem(name: "includeEpisode", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])
        let page: ArrQueuePage<SonarrHistoryRecord>
        do { page = try JSONDecoder().decode(ArrQueuePage<SonarrHistoryRecord>.self, from: data) }
        catch { throw HTTPError.decoding(error) }
        return page.records.compactMap(Self.unifyHistory)
    }

    private static func unifyHistory(_ r: SonarrHistoryRecord) -> HistoryItem? {
        guard let dateStr = r.date, let date = parseArrDate(dateStr) else { return nil }
        var subtitle: String?
        if let ep = r.episode, let s = ep.seasonNumber, let e = ep.episodeNumber {
            let code = String(format: "S%02dE%02d", s, e)
            subtitle = (ep.title?.isEmpty == false) ? "\(code) · \(ep.title!)" : code
        }
        return HistoryItem(
            id: "sonarr-h-\(r.id)",
            source: .sonarr,
            date: date,
            eventType: HistoryItem.EventType.parse(r.eventType),
            title: r.series?.title ?? r.sourceTitle ?? "Unknown",
            subtitle: subtitle,
            sourceTitle: r.sourceTitle,
            quality: r.quality?.name,
            customFormats: (r.customFormats ?? []).map(\.name),
            customFormatScore: r.customFormatScore ?? 0
        )
    }

    func fetchHealth() async throws -> [ArrHealthRecord] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "/api/v3/health")
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])
        return (try? JSONDecoder().decode([ArrHealthRecord].self, from: data)) ?? []
    }

    private static func unifyCalendar(_ r: SonarrCalendarRecord, baseURL: String) -> UpcomingItem? {
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
        let (poster, auth) = pickPosterURL(from: r.series?.images, coverTypes: ["poster"], baseURL: baseURL)

        return UpcomingItem(
            id: "sonarr-cal-\(r.id)",
            source: .sonarr,
            title: seriesTitle,
            subtitle: subtitle,
            airDate: date,
            releaseType: "Airing",
            hasFile: r.hasFile ?? false,
            overview: r.overview,
            posterURL: poster,
            posterRequiresAuth: auth
        )
    }

    private static func unify(_ r: SonarrQueueRecord, baseURL: String, fileMap: [Int: SonarrEpisodeFile]) -> QueueItem {
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
        let (poster, posterAuth) = pickPosterURL(from: r.series?.images, coverTypes: ["poster"], baseURL: baseURL)

        let existingFile = (r.episode?.episodeFileId).flatMap { id in id > 0 ? fileMap[id] : nil }
        let isUpgrade = existingFile != nil || (r.episode?.hasFile ?? false)

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
            isUpgrade: isUpgrade,
            existingCustomFormats: (existingFile?.customFormats ?? []).map(\.name),
            existingCustomFormatScore: existingFile?.customFormatScore,
            existingQuality: existingFile?.quality?.name,
            contentSlug: r.series?.titleSlug,
            posterURL: poster,
            posterRequiresAuth: posterAuth
        )
    }
}
