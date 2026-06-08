import Foundation

public actor WhisparrClient: ArrAPIClient {
    public let config: ServiceConfig
    public let apiBase = "/api/v3"
    public let http = HTTPClient()

    init(config: ServiceConfig) {
        self.config = config
    }

    func testConnection() async throws -> String {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/system/status")
        let data = try await http.get(url, headers: apiHeaders)
        struct Status: Decodable { let version: String? }
        let status = try? JSONDecoder().decode(Status.self, from: data)
        return status?.version.map { "Whisparr \($0)" } ?? "OK"
    }

    func fetchQueue() async throws -> [QueueItem] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }

        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/queue",
            query: [
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "includeMovie", value: "true"),
                URLQueryItem(name: "includeUnknownMovieItems", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)

        let page: ArrQueuePage<WhisparrQueueRecord>
        do { page = try JSONDecoder().decode(ArrQueuePage<WhisparrQueueRecord>.self, from: data) }
        catch { throw HTTPError.decoding(error) }
        let baseURL = config.baseURL
        return page.records.map { Self.unify($0, baseURL: baseURL) }
    }

    func fetchCalendar() async throws -> [UpcomingItem] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]

        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/calendar",
            query: [
                URLQueryItem(name: "start", value: fmt.string(from: now)),
                URLQueryItem(name: "end", value: fmt.string(from: end)),
                URLQueryItem(name: "unmonitored", value: "false"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)

        let records: [WhisparrCalendarRecord]
        do {
            records = try JSONDecoder().decode([WhisparrCalendarRecord].self, from: data)
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
            path: "\(apiBase)/history",
            query: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pageSize", value: "50"),
                URLQueryItem(name: "sortKey", value: "date"),
                URLQueryItem(name: "sortDirection", value: "descending"),
                URLQueryItem(name: "includeMovie", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)
        let page: ArrQueuePage<WhisparrHistoryRecord>
        do { page = try JSONDecoder().decode(ArrQueuePage<WhisparrHistoryRecord>.self, from: data) }
        catch { throw HTTPError.decoding(error) }
        return page.records.compactMap(Self.unifyHistory)
    }

    func fetchAllMovies() async throws -> [WhisparrLibraryRecord] {
        if DemoMode.isActive { return [] }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([WhisparrLibraryRecord].self, from: data)) ?? []
    }

    func fetchHealth() async throws -> [ArrHealthRecord] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/health")
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([ArrHealthRecord].self, from: data)) ?? []
    }

    func fetchMovieDetails(id: Int) async throws -> RadarrMovieDetail {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie/\(id)")
        let data = try await http.get(url, headers: apiHeaders)
        do { return try JSONDecoder().decode(RadarrMovieDetail.self, from: data) }
        catch { throw HTTPError.decoding(error) }
    }

    func deleteQueueItem(id: Int, removeFromClient: Bool = true, blocklist: Bool = false) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/queue/\(id)",
            query: [
                URLQueryItem(name: "removeFromClient", value: removeFromClient ? "true" : "false"),
                URLQueryItem(name: "blocklist", value: blocklist ? "true" : "false"),
            ]
        )
        _ = try await http.delete(url, headers: apiHeaders)
    }

    /// Force-grab a pending/delayed queue item now (no download-client item yet).
    func grabQueueItem(id: Int) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/queue/grab/\(id)")
        let data = try JSONSerialization.data(withJSONObject: [String: Any]())
        _ = try await http.post(url, headers: apiHeaders.merging(["Content-Type": "application/json"]) { $1 }, body: data)
    }

    private static func unifyCalendar(_ r: WhisparrCalendarRecord, baseURL: String) -> UpcomingItem? {
        let (dateStr, releaseType): (String?, String) =
            if r.digitalRelease != nil { (r.digitalRelease, "Digital") }
            else if r.physicalRelease != nil { (r.physicalRelease, "Physical") }
            else { (r.inCinemas, "In Cinemas") }

        guard let dateStr, let date = parseArrDate(dateStr) else { return nil }

        let title = r.year.map { "\(r.title) (\($0))" } ?? r.title
        let (poster, auth) = (r.images ?? []).posterURL(baseURL: baseURL)

        return UpcomingItem(
            id: "whisparr-cal-\(r.id)",
            source: .whisparr,
            title: title,
            subtitle: nil,
            airDate: date,
            releaseType: releaseType,
            hasFile: r.hasFile ?? false,
            overview: r.overview,
            posterURL: poster,
            posterRequiresAuth: auth,
            imdb: r.ratings?.imdb?.value,
            runtime: r.runtime,
            entityId: r.id
        )
    }

    private static func unifyHistory(_ r: WhisparrHistoryRecord) -> HistoryItem? {
        guard let dateStr = r.date, let date = parseArrDate(dateStr) else { return nil }
        return HistoryItem(
            id: "whisparr-h-\(r.id)",
            source: .whisparr,
            date: date,
            eventType: HistoryItem.EventType.parse(r.eventType),
            title: r.movie?.title ?? r.sourceTitle ?? "Unknown",
            subtitle: nil,
            sourceTitle: r.sourceTitle,
            quality: r.quality?.name,
            customFormats: (r.customFormats ?? []).map(\.name),
            customFormatScore: r.customFormatScore ?? 0
        )
    }

    private static func unify(_ r: WhisparrQueueRecord, baseURL: String) -> QueueItem {
        let total = Int64(r.size ?? 0)
        let left = Int64(r.sizeleft ?? 0)
        let progress = total > 0 ? max(0, min(1, 1.0 - Double(left) / Double(total))) : 0.0

        let movieTitle: String
        if let m = r.movie {
            movieTitle = m.year.map { "\(m.title) (\($0))" } ?? m.title
        } else {
            movieTitle = r.title ?? "Unknown"
        }
        let (poster, posterAuth) = (r.movie?.images ?? []).posterURL(baseURL: baseURL)

        return QueueItem(
            id: "whisparr-\(r.id)",
            source: .whisparr,
            arrQueueId: r.id,
            downloadId: r.downloadId,
            downloadProtocol: parseProtocol(r.protocol),
            downloadClient: r.downloadClient,
            indexer: r.indexer,
            title: movieTitle,
            subtitle: nil,
            releaseName: r.title,
            status: parseStatus(arrStatus: r.status, trackedState: r.trackedDownloadState),
            progress: progress,
            sizeTotal: total,
            sizeLeft: left,
            timeLeft: r.timeleft,
            customFormats: (r.customFormats ?? []).map(\.name),
            customFormatScore: r.customFormatScore ?? 0,
            quality: r.quality?.name,
            isUpgrade: r.movie?.movieFile != nil || (r.movie?.hasFile ?? false),
            contentSlug: r.movie?.titleSlug,
            entityId: r.movieId ?? r.movie?.id,
            posterURL: poster,
            posterRequiresAuth: posterAuth,
            statusMessages: r.statusMessages.flattenToLines()
        )
    }
}
