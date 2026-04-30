import Foundation

actor RadarrClient {
    private let config: ServiceConfig
    private let http = HTTPClient()

    private struct CachedMovieFile { let file: RadarrMovieFile; let expiry: Date }
    private var movieFileCache: [Int: CachedMovieFile] = [:]
    private let movieFileCacheTTL: TimeInterval = 60

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
        return status?.version.map { "Radarr \($0)" } ?? "OK"
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
        let baseURL = config.baseURL

        let movieIds = Set(page.records.compactMap { $0.movieId ?? $0.movie?.id }
            .filter { $0 > 0 })
        let fileMap = (try? await fetchMovieFiles(movieIds: movieIds)) ?? [:]
        return page.records.map { Self.unify($0, baseURL: baseURL, fileMap: fileMap) }
    }

    private func fetchMovieFiles(movieIds: Set<Int>) async throws -> [Int: RadarrMovieFile] {
        guard !movieIds.isEmpty else { return [:] }
        let now = Date()
        var result: [Int: RadarrMovieFile] = [:]
        var misses: Set<Int> = []
        for id in movieIds {
            if let cached = movieFileCache[id], cached.expiry > now {
                result[id] = cached.file
            } else {
                misses.insert(id)
            }
        }
        guard !misses.isEmpty else { return result }

        let items = misses.map { URLQueryItem(name: "movieId", value: String($0)) }
        let url = try http.url(base: config.baseURL, path: "/api/v3/moviefile", query: items)
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])
        let files = (try? JSONDecoder().decode([RadarrMovieFile].self, from: data)) ?? []

        let expiry = now.addingTimeInterval(movieFileCacheTTL)
        let returnedIds = Set(files.compactMap { $0.movieId })
        for f in files {
            if let mid = f.movieId {
                result[mid] = f
                movieFileCache[mid] = CachedMovieFile(file: f, expiry: expiry)
            }
        }
        // Movies with no file return nothing — invalidate any stale cache for them.
        for id in misses where !returnedIds.contains(id) {
            movieFileCache.removeValue(forKey: id)
        }
        return result
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
                URLQueryItem(name: "includeMovie", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])
        let page: ArrQueuePage<RadarrHistoryRecord>
        do { page = try JSONDecoder().decode(ArrQueuePage<RadarrHistoryRecord>.self, from: data) }
        catch { throw HTTPError.decoding(error) }
        return page.records.compactMap(Self.unifyHistory)
    }

    private static func unifyHistory(_ r: RadarrHistoryRecord) -> HistoryItem? {
        guard let dateStr = r.date, let date = parseArrDate(dateStr) else { return nil }
        return HistoryItem(
            id: "radarr-h-\(r.id)",
            source: .radarr,
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

    func deleteQueueItem(id: Int, removeFromClient: Bool = true, blocklist: Bool = false) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "/api/v3/queue/\(id)",
            query: [
                URLQueryItem(name: "removeFromClient", value: removeFromClient ? "true" : "false"),
                URLQueryItem(name: "blocklist", value: blocklist ? "true" : "false"),
            ]
        )
        _ = try await http.delete(url, headers: ["X-Api-Key": config.apiKey])
    }

    func fetchHealth() async throws -> [ArrHealthRecord] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "/api/v3/health")
        let data = try await http.get(url, headers: ["X-Api-Key": config.apiKey])
        return (try? JSONDecoder().decode([ArrHealthRecord].self, from: data)) ?? []
    }

    private static func unifyCalendar(_ r: RadarrCalendarRecord, baseURL: String) -> UpcomingItem? {
        let (dateStr, releaseType): (String?, String) =
            if r.digitalRelease != nil { (r.digitalRelease, "Digital") }
            else if r.physicalRelease != nil { (r.physicalRelease, "Physical") }
            else { (r.inCinemas, "In Cinemas") }

        guard let dateStr, let date = parseArrDate(dateStr) else { return nil }

        let title = r.year.map { "\(r.title) (\($0))" } ?? r.title
        let (poster, auth) = pickPosterURL(from: r.images, coverTypes: ["poster"], baseURL: baseURL)

        return UpcomingItem(
            id: "radarr-cal-\(r.id)",
            source: .radarr,
            title: title,
            subtitle: nil,
            airDate: date,
            releaseType: releaseType,
            hasFile: r.hasFile ?? false,
            overview: r.overview,
            posterURL: poster,
            posterRequiresAuth: auth
        )
    }

    private static func unify(_ r: RadarrQueueRecord, baseURL: String, fileMap: [Int: RadarrMovieFile]) -> QueueItem {
        let total = Int64(r.size ?? 0)
        let left = Int64(r.sizeleft ?? 0)
        let progress = total > 0 ? max(0, min(1, 1.0 - Double(left) / Double(total))) : 0.0

        let movieTitle: String
        if let m = r.movie {
            movieTitle = m.year.map { "\(m.title) (\($0))" } ?? m.title
        } else {
            movieTitle = r.title ?? "Unknown"
        }
        let (poster, posterAuth) = pickPosterURL(from: r.movie?.images, coverTypes: ["poster"], baseURL: baseURL)

        let existingFile = (r.movieId ?? r.movie?.id).flatMap { fileMap[$0] }

        return QueueItem(
            id: "radarr-\(r.id)",
            source: .radarr,
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
            isUpgrade: existingFile != nil || r.movie?.movieFile != nil || (r.movie?.hasFile ?? false),
            existingCustomFormats: (existingFile?.customFormats ?? r.movie?.movieFile?.customFormats ?? []).map(\.name),
            existingCustomFormatScore: existingFile?.customFormatScore ?? r.movie?.movieFile?.customFormatScore,
            existingQuality: existingFile?.quality?.name ?? r.movie?.movieFile?.quality?.name,
            existingSize: existingFile?.size ?? r.movie?.movieFile?.size,
            existingFileName: (existingFile?.relativePath ?? r.movie?.movieFile?.relativePath).map { URL(fileURLWithPath: $0).lastPathComponent },
            contentSlug: r.movie?.titleSlug,
            posterURL: poster,
            posterRequiresAuth: posterAuth
        )
    }
}

/// Resolves a poster URL from an Arr `images[]` array.
/// Prefers `remoteUrl` (typically TMDB / MusicBrainz, no auth) over the local server URL.
/// Returns the URL plus whether it requires the X-Api-Key header.
func pickPosterURL(
    from images: [ArrImage]?,
    coverTypes: [String],
    baseURL: String
) -> (URL?, Bool) {
    guard let images else { return (nil, false) }
    let normalized = coverTypes.map { $0.lowercased() }
    let match = images.first { img in
        guard let type = img.coverType?.lowercased() else { return false }
        return normalized.contains(type)
    }
    guard let match else { return (nil, false) }

    if let remote = match.remoteUrl, let url = URL(string: remote) {
        return (url, false)
    }
    if let path = match.url, let base = URL(string: baseURL) {
        // Some Arrs return absolute, some relative. Strip query (cache-busting hash) for stable cache keys.
        if let abs = URL(string: path), abs.scheme != nil {
            return (abs, true)
        }
        let trimmed = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let composed = URL(string: trimmed, relativeTo: base)?.absoluteURL
        return (composed, true)
    }
    return (nil, false)
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
        case "importing", "importpending": return .importing
        case "imported": return .completed
        case "importblocked": return .warning
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
