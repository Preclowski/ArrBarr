import Foundation

actor LidarrClient {
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
            path: "/api/v1/queue",
            query: [
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "includeArtist", value: "true"),
                URLQueryItem(name: "includeAlbum", value: "true"),
                URLQueryItem(name: "includeUnknownArtistItems", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])

        let page: ArrQueuePage<LidarrQueueRecord>
        do { page = try JSONDecoder().decode(ArrQueuePage<LidarrQueueRecord>.self, from: data) }
        catch { throw HTTPError.decoding(error) }
        return page.records.map { Self.unify($0) }
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
            path: "/api/v1/calendar",
            query: [
                URLQueryItem(name: "start", value: fmt.string(from: now)),
                URLQueryItem(name: "end", value: fmt.string(from: end)),
                URLQueryItem(name: "unmonitored", value: "false"),
            ]
        )
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])

        let records: [LidarrCalendarRecord]
        do {
            records = try JSONDecoder().decode([LidarrCalendarRecord].self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }

        return records.compactMap { Self.unifyCalendar($0) }
    }

    private static func unifyCalendar(_ r: LidarrCalendarRecord) -> UpcomingItem? {
        guard let dateStr = r.releaseDate, let date = parseArrDate(dateStr) else { return nil }

        let artistName = r.artist?.artistName
        let title = artistName.map { "\($0) — \(r.title)" } ?? r.title

        return UpcomingItem(
            id: "lidarr-cal-\(r.id)",
            source: .lidarr,
            title: title,
            subtitle: nil,
            airDate: date,
            releaseType: "Album",
            hasFile: false,
            overview: r.overview
        )
    }

    private static func unify(_ r: LidarrQueueRecord) -> QueueItem {
        let total = Int64(r.size ?? 0)
        let left = Int64(r.sizeleft ?? 0)
        let progress = total > 0 ? max(0, min(1, 1.0 - Double(left) / Double(total))) : 0.0

        let artistName = r.artist?.artistName ?? r.album?.artist?.artistName
        let albumTitle = r.album?.title ?? r.title ?? "Unknown"
        let displayTitle = artistName.map { "\($0) — \(albumTitle)" } ?? albumTitle

        return QueueItem(
            id: "lidarr-\(r.id)",
            source: .lidarr,
            arrQueueId: r.id,
            downloadId: r.downloadId,
            downloadProtocol: parseProtocol(r.protocol),
            downloadClient: r.downloadClient,
            title: displayTitle,
            subtitle: nil,
            status: parseStatus(arrStatus: r.status, trackedState: r.trackedDownloadState),
            progress: progress,
            sizeTotal: total,
            sizeLeft: left,
            timeLeft: r.timeleft,
            customFormats: (r.customFormats ?? []).map(\.name),
            customFormatScore: r.customFormatScore ?? 0,
            quality: r.quality?.name,
            isUpgrade: false,
            contentSlug: r.album?.foreignAlbumId
        )
    }
}
