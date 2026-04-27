import Foundation

actor RadarrClient {
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
                URLQueryItem(name: "includeMovie", value: "true"),
                URLQueryItem(name: "includeUnknownMovieItems", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])

        let page: ArrQueuePage<RadarrQueueRecord>
        do { page = try JSONDecoder().decode(ArrQueuePage<RadarrQueueRecord>.self, from: data) }
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
            path: "/api/v3/calendar",
            query: [
                URLQueryItem(name: "start", value: fmt.string(from: now)),
                URLQueryItem(name: "end", value: fmt.string(from: end)),
                URLQueryItem(name: "unmonitored", value: "false"),
            ]
        )
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])

        let records: [RadarrCalendarRecord]
        do {
            records = try JSONDecoder().decode([RadarrCalendarRecord].self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }

        return records.compactMap { Self.unifyCalendar($0) }
    }

    private static func unifyCalendar(_ r: RadarrCalendarRecord) -> UpcomingItem? {
        let (dateStr, releaseType): (String?, String) =
            if r.digitalRelease != nil { (r.digitalRelease, "Digital") }
            else if r.physicalRelease != nil { (r.physicalRelease, "Physical") }
            else { (r.inCinemas, "In Cinemas") }

        guard let dateStr, let date = parseArrDate(dateStr) else { return nil }

        let title = r.year.map { "\(r.title) (\($0))" } ?? r.title

        return UpcomingItem(
            id: "radarr-cal-\(r.id)",
            source: .radarr,
            title: title,
            subtitle: nil,
            airDate: date,
            releaseType: releaseType,
            hasFile: r.hasFile ?? false,
            overview: r.overview
        )
    }

    private static func unify(_ r: RadarrQueueRecord) -> QueueItem {
        let total = Int64(r.size ?? 0)
        let left = Int64(r.sizeleft ?? 0)
        let progress = total > 0 ? max(0, min(1, 1.0 - Double(left) / Double(total))) : 0.0

        let movieTitle: String
        if let m = r.movie {
            movieTitle = m.year.map { "\(m.title) (\($0))" } ?? m.title
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
            quality: r.quality?.name,
            isUpgrade: r.movie?.hasFile ?? false,
            contentSlug: r.movie?.titleSlug
        )
    }
}

func parseArrDate(_ string: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: string) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: string) { return d }
    iso.formatOptions = [.withFullDate]
    return iso.date(from: string)
}

func parseProtocol(_ raw: String?) -> QueueItem.DownloadProtocol {
    switch raw?.lowercased() {
    case "usenet": return .usenet
    case "torrent": return .torrent
    default: return .unknown
    }
}

func parseStatus(arrStatus: String?, trackedState: String?) -> QueueItem.Status {
    let status = arrStatus?.lowercased()
    if status == "paused" { return .paused }

    if let tracked = trackedState?.lowercased() {
        switch tracked {
        case "downloading": return .downloading
        case "downloadfailed", "failedpending": return .failed
        case "imported", "importing", "importpending": return .completed
        default: break
        }
    }
    switch status {
    case "downloading": return .downloading
    case "queued", "delay": return .queued
    case "completed": return .completed
    case "warning": return .warning
    case "failed": return .failed
    default: return .unknown
    }
}
