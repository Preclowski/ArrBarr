import Foundation

public actor WhisparrClient: ArrAPIClient {
    public let config: ServiceConfig
    public let apiBase = "/api/v3"
    public let serviceName = "Whisparr"
    public let http = HTTPClient()

    /// Whisparr is a Radarr fork, so `/moviefile` answers the same shape and
    /// `RadarrMovieFile` decodes it. See `SonarrClient.episodeFileCacheTTL` for
    /// why the TTL is what it is.
    private struct CachedMovieFile { let file: RadarrMovieFile; let expiry: Date }
    private var movieFileCache: [Int: CachedMovieFile] = [:]
    private let movieFileCacheTTL: TimeInterval = 15 * 60

    init(config: ServiceConfig) {
        self.config = config
    }

    func fetchQueue() async throws -> [QueueItem] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }

        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/queue",
            query: [
                URLQueryItem(name: "pageSize", value: String(Self.queuePageSize)),
                // See LidarrClient.fetchQueue. Dropping `includeMovie` here cost
                // more than in Radarr: this client had no `/moviefile` side-load
                // at all and read the whole existing-file diff off the embedded
                // `movie.movieFile`. That side-load is now ported below, so the
                // upgrade card survives the leaner queue.
                URLQueryItem(name: "includeUnknownMovieItems", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)

        let page: ArrQueuePage<WhisparrQueueRecord>
        do { page = try JSONDecoder().decode(ArrQueuePage<WhisparrQueueRecord>.self, from: data) }
        catch { throw HTTPError.decoding(error) }
        warnIfQueueTruncated(returned: page.records.count, totalRecords: page.totalRecords)
        let baseURL = config.baseURL

        let movieIds = Set(page.records.compactMap { $0.movieId ?? $0.movie?.id }.filter { $0 > 0 })
        async let metaMap = resolveMovieMetadata(ids: Array(movieIds), baseURL: baseURL)
        let fileMap = (try? await fetchMovieFiles(movieIds: movieIds)) ?? [:]
        let meta = await metaMap
        return page.records.map { Self.unify($0, baseURL: baseURL, fileMap: fileMap, meta: meta) }
    }

    /// Ported from `RadarrClient` — Whisparr's queue used to carry the on-disk
    /// file inline and no longer does.
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
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/moviefile", query: items)
        let data = try await http.get(url, headers: apiHeaders)
        let files = (try? JSONDecoder().decode([RadarrMovieFile].self, from: data)) ?? []

        let expiry = now.addingTimeInterval(movieFileCacheTTL)
        let returnedIds = Set(files.compactMap { $0.movieId })
        for f in files {
            if let mid = f.movieId {
                result[mid] = f
                movieFileCache[mid] = CachedMovieFile(file: f, expiry: expiry)
            }
        }
        // A movie with no file returns nothing — clear any stale entry for it.
        for id in misses where !returnedIds.contains(id) {
            movieFileCache.removeValue(forKey: id)
        }
        return result
    }

    private func resolveMovieMetadata(ids: [Int], baseURL: String) async -> [Int: TitleMetadataStore.Metadata] {
        await resolveMetadata(ids: ids, source: .whisparr, kind: .movie) { id in
            guard let detail = try? await self.fetchMovieDetails(id: id) else { return nil }
            let (poster, auth) = (detail.images ?? []).posterURL(baseURL: baseURL)
            return TitleMetadataStore.Metadata(
                title: detail.title, year: detail.year, slug: detail.titleSlug,
                posterURL: poster, posterRequiresAuth: auth
            )
        }
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
        if DemoMode.isActive { return DemoMocks.whisparrLibrary() }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([WhisparrLibraryRecord].self, from: data)) ?? []
    }

    func fetchMovieDetails(id: Int) async throws -> RadarrMovieDetail {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let demo = DemoMocks.whisparrDetails[id] { return demo }
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie/\(id)")
        let data = try await http.get(url, headers: apiHeaders)
        do { return try JSONDecoder().decode(RadarrMovieDetail.self, from: data) }
        catch { throw HTTPError.decoding(error) }
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

    /// Wire record -> `QueueItem`. Internal rather than private so
    /// `QueueUnificationTests` can pin it: this is where every displayed field
    /// on a queue row is decided, and nothing else in the suite reaches it.
    static func unify(
        _ r: WhisparrQueueRecord,
        baseURL: String,
        fileMap: [Int: RadarrMovieFile] = [:],
        meta: [Int: TitleMetadataStore.Metadata] = [:]
    ) -> QueueItem {
        let total = clampedBytes(r.size)
        let left = clampedBytes(r.sizeleft)
        let progress = total > 0 ? max(0, min(1, 1.0 - Double(left) / Double(total))) : 0.0

        let movieId = r.movieId ?? r.movie?.id
        let cached = movieId.flatMap { meta[$0] }
        let existingFile = movieId.flatMap { fileMap[$0] }
        let movieTitle: String
        if let c = cached {
            movieTitle = c.year.map { "\(c.title) (\($0))" } ?? c.title
        } else if let m = r.movie {
            movieTitle = m.year.map { "\(m.title) (\($0))" } ?? m.title
        } else {
            movieTitle = r.title ?? "Unknown"
        }
        var poster = cached?.posterURL
        var posterAuth = cached?.posterRequiresAuth ?? false
        if poster == nil {
            (poster, posterAuth) = (r.movie?.images ?? []).posterURL(baseURL: baseURL)
        }

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
            status: parseStatus(arrStatus: r.status, trackedState: r.trackedDownloadState, trackedStatus: r.trackedDownloadStatus),
            progress: progress,
            sizeTotal: total,
            sizeLeft: left,
            timeLeft: r.timeleft,
            customFormats: (r.customFormats ?? []).map(\.name),
            customFormatScore: r.customFormatScore ?? 0,
            quality: r.quality?.name,
            isUpgrade: existingFile != nil || r.movie?.movieFile != nil || (r.movie?.hasFile ?? false),
            // Side-loaded `/moviefile` first, embedded `movie.movieFile` second
            // — same precedence as Radarr. The embedded arm is dead while the
            // queue stays lean but is kept: it is exactly one `?? ` per field,
            // and it is what makes a failed side-load degrade instead of blank.
            existingCustomFormats: (existingFile?.customFormats ?? r.movie?.movieFile?.customFormats ?? []).map(\.name),
            existingCustomFormatScore: existingFile?.customFormatScore ?? r.movie?.movieFile?.customFormatScore,
            existingQuality: existingFile?.quality?.name ?? r.movie?.movieFile?.quality?.name,
            existingSize: existingFile?.size ?? r.movie?.movieFile?.size,
            existingFileName: (existingFile?.relativePath ?? r.movie?.movieFile?.relativePath).map { URL(fileURLWithPath: $0).lastPathComponent },
            contentSlug: cached?.slug ?? r.movie?.titleSlug,
            entityId: r.movieId ?? r.movie?.id,
            posterURL: poster,
            posterRequiresAuth: posterAuth,
            statusMessages: r.statusMessages.flattenToLines()
        )
    }
}
