import Foundation

public actor RadarrClient: ArrAPIClient {
    public let config: ServiceConfig
    public let apiBase = "/api/v3"
    public let serviceName = "Radarr"
    public let http = HTTPClient()

    private struct CachedMovieFile { let file: RadarrMovieFile; let expiry: Date }
    private var movieFileCache: [Int: CachedMovieFile] = [:]
    /// See `SonarrClient.episodeFileCacheTTL` — same reasoning, same trade.
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
                // See LidarrClient.fetchQueue — the embedded entity is a
                // per-poll cost for fields that never change; the store holds
                // them and `movieId` is top-level. `includeUnknownMovieItems`
                // is a different flag and stays: without it, downloads Radarr
                // can't map to a library movie drop out of the queue.
                URLQueryItem(name: "includeUnknownMovieItems", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)

        let page: ArrQueuePage<RadarrQueueRecord>
        do { page = try JSONDecoder().decode(ArrQueuePage<RadarrQueueRecord>.self, from: data) }
        catch { throw HTTPError.decoding(error) }
        warnIfQueueTruncated(returned: page.records.count, totalRecords: page.totalRecords)
        let baseURL = config.baseURL

        let movieIds = Set(page.records.compactMap { $0.movieId ?? $0.movie?.id }
            .filter { $0 > 0 })
        async let metaMap = resolveMovieMetadata(ids: Array(movieIds), baseURL: baseURL)
        let fileMap = (try? await fetchMovieFiles(movieIds: movieIds)) ?? [:]
        let meta = await metaMap
        return page.records.map { Self.unify($0, baseURL: baseURL, fileMap: fileMap, meta: meta) }
    }

    private func resolveMovieMetadata(ids: [Int], baseURL: String) async -> [Int: TitleMetadataStore.Metadata] {
        await resolveMetadata(ids: ids, source: .radarr, kind: .movie) { id in
            guard let detail = try? await self.fetchMovieDetails(id: id) else { return nil }
            let (poster, auth) = (detail.images ?? []).posterURL(baseURL: baseURL)
            return TitleMetadataStore.Metadata(
                title: detail.title, year: detail.year, slug: detail.titleSlug,
                posterURL: poster, posterRequiresAuth: auth,
                mediaServerKeys: detail.mediaServerKeys.map(\.rawKey)
            )
        }
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
            path: "\(apiBase)/calendar",
            query: [
                URLQueryItem(name: "start", value: fmt.string(from: now)),
                URLQueryItem(name: "end", value: fmt.string(from: end)),
                URLQueryItem(name: "unmonitored", value: "false"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)

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

    func fetchMovieDetails(id: Int) async throws -> RadarrMovieDetail {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let demo = await DemoMonitorState.apply(movie: DemoMocks.radarrMovieDetail(id: id)) { return demo }
            throw HTTPError.decoding(NSError(domain: "demo", code: 404))
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie/\(id)")
        let data = try await http.get(url, headers: apiHeaders)
        do { return try JSONDecoder().decode(RadarrMovieDetail.self, from: data) }
        catch { throw HTTPError.decoding(error) }
    }

    /// Fetches the movie-file record for a movie. `/movie/{id}` returns
    /// movieFile inline but Radarr strips `customFormats` from that
    /// payload; the canonical place for the file's CF list is
    /// `/moviefile?movieId={id}`. Used by DetailView to enrich the
    /// "existing file" banner with chips.
    ///
    /// Note on the URL: the `movieId` value is passed via `query:` so
    /// `HTTPClient.url` formats `?movieId=…` correctly. An earlier
    /// draft baked the query string into `path:`, which got
    /// percent-encoded — Radarr saw `%3FmovieId=…`, returned 404, and
    /// the caller silently fell back to the stripped inline file. The
    /// surface symptom was "no CF chips in movie detail" (the
    /// architect catch).
    func fetchMovieFile(movieId: Int) async throws -> ArrFile? {
        if DemoMode.isActive { return DemoMocks.movieFile(movieId: movieId) }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/moviefile",
            query: [URLQueryItem(name: "movieId", value: String(movieId))]
        )
        let data = try await http.get(url, headers: apiHeaders)
        let files = (try? JSONDecoder().decode([ArrFile].self, from: data)) ?? []
        return files.first
    }

    /// Cast + crew for a movie via `/api/v3/credit?movieId=`. Radarr stores
    /// these from its metadata provider, so this needs no app-side TMDB key.
    func fetchCredits(movieId: Int) async throws -> [ArrCredit] {
        if DemoMode.isActive { return DemoMocks.radarrMovieCredits(movieId: movieId) }
        return try await get("/credit", query: [URLQueryItem(name: "movieId", value: String(movieId))])
    }

    /// Force a manual indexer search for a specific movie. Mirrors the
    /// Sonarr per-episode search pattern — same `/command` endpoint,
    /// different name. Useful for "this movie didn't grab, try again"
    /// or upgrade-quality kicks.
    func searchMovie(movieId: Int) async throws {
        try await postCommand([
            "name": "MoviesSearch",
            "movieIds": [movieId],
        ])
    }

    /// LLM-suggested titles surface as cards. Mirrors Radarr's
    /// `/api/v3/movie/lookup?term=…`.
    func lookupMovies(term: String) async throws -> [RadarrLookupRecord] {
        if DemoMode.isActive { return DemoMocks.radarrLookup(term: term) }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/movie/lookup",
            query: [URLQueryItem(name: "term", value: term)]
        )
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([RadarrLookupRecord].self, from: data)) ?? []
    }

    func fetchAllMovies() async throws -> [RadarrLibraryRecord] {
        if DemoMode.isActive { return DemoMocks.radarrLibrary() }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/movie")
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([RadarrLibraryRecord].self, from: data)) ?? []
    }

    /// Alternate titles keyed by movie id, for the library filter's search
    /// index.
    ///
    /// Two sources, in order. Radarr inlines `alternateTitles[]` on
    /// `/api/v3/movie` in some versions and omits them in others, so the
    /// inline lists are read first — they need no extra request and their
    /// join to a movie is structural, so it cannot be wrong. Only when the
    /// whole library came back without a single one does this fall back to
    /// the dedicated `/alttitle` table, joined on `movieId`.
    ///
    /// Best-effort throughout: a missing endpoint (or a `movieId` that newer
    /// Radarr leaves empty now that alt titles hang off movie *metadata*)
    /// costs the filter some reach and nothing else, so a failure here must
    /// never fail a library load.
    func alternateTitleMap(for movies: [RadarrLibraryRecord]) async -> [Int: [String]] {
        var inline: [Int: [String]] = [:]
        for movie in movies {
            guard let id = movie.id else { continue }
            let titles = (movie.alternateTitles ?? []).compactMap(\.title).filter { !$0.isEmpty }
            if !titles.isEmpty { inline[id] = titles }
        }
        if !inline.isEmpty { return inline }

        guard !DemoMode.isActive, config.isConfigured, !config.apiKey.isEmpty,
              let url = try? http.url(base: config.baseURL, path: "\(apiBase)/alttitle"),
              let data = try? await http.get(url, headers: apiHeaders),
              let rows = try? JSONDecoder().decode([ArrAlternateTitle].self, from: data)
        else { return [:] }

        var out: [Int: [String]] = [:]
        for row in rows {
            guard let id = row.movieId, id > 0,
                  let title = row.title, !title.isEmpty else { continue }
            out[id, default: []].append(title)
        }
        return out
    }

    private static func unifyCalendar(_ r: RadarrCalendarRecord, baseURL: String) -> UpcomingItem? {
        let (dateStr, releaseType): (String?, String) =
            if r.digitalRelease != nil { (r.digitalRelease, "Digital") }
            else if r.physicalRelease != nil { (r.physicalRelease, "Physical") }
            else { (r.inCinemas, "In Cinemas") }

        guard let dateStr, let date = parseArrDate(dateStr) else { return nil }

        let title = r.year.map { "\(r.title) (\($0))" } ?? r.title
        let (poster, auth) = (r.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: r.mediaServerKeys)

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
            posterRequiresAuth: auth,
            imdb: r.ratings?.imdb?.value,
            tmdb: r.ratings?.tmdb?.value,
            runtime: r.runtime,
            entityId: r.id,
            genres: r.genres ?? [],
            certification: r.certification,
            releaseStatus: r.status,
            ratingRt: r.ratings?.rottenTomatoes?.value,
            ratingMetacritic: r.ratings?.metacritic?.value,
            qualityProfileId: r.qualityProfileId
        )
    }

    /// Wire record -> `QueueItem`. Internal rather than private so
    /// `QueueUnificationTests` can pin it: this is where every displayed field
    /// on a queue row is decided, and nothing else in the suite reaches it.
    static func unify(
        _ r: RadarrQueueRecord,
        baseURL: String,
        fileMap: [Int: RadarrMovieFile],
        meta: [Int: TitleMetadataStore.Metadata] = [:]
    ) -> QueueItem {
        let total = clampedBytes(r.size)
        let left = clampedBytes(r.sizeleft)
        let progress = total > 0 ? max(0, min(1, 1.0 - Double(left) / Double(total))) : 0.0

        // Store first, embedded movie second, release name last. See
        // `LidarrClient.unify` for why the embedded path is kept rather than
        // deleted.
        let cached = (r.movieId ?? r.movie?.id).flatMap { meta[$0] }
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
            (poster, posterAuth) = (r.movie?.images ?? []).posterURL(
                baseURL: baseURL, mediaServerKeys: r.movie?.mediaServerKeys ?? []
            )
        }

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
            status: parseStatus(arrStatus: r.status, trackedState: r.trackedDownloadState, trackedStatus: r.trackedDownloadStatus),
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
            contentSlug: cached?.slug ?? r.movie?.titleSlug,
            entityId: r.movieId ?? r.movie?.id,
            posterURL: poster,
            posterRequiresAuth: posterAuth,
            statusMessages: r.statusMessages.flattenToLines()
        )
    }
}

/// Parses the assorted date shapes an arr puts on the wire.
///
/// Order matters: `ISO8601DateFormatter` with `.withFullDate` is *lenient* —
/// it happily accepts "2024-03-15T14:30:00" by matching the date prefix and
/// silently discarding the time — so the zone-less date-time shape has to be
/// tried before it, or "airs at 20:00" renders as midnight.
func parseArrDate(_ string: String) -> Date? {
    ArrDateParser.shared.parse(string)
}

/// `parseArrDate`'s engine: the four `ISO8601DateFormatter` shapes built once,
/// plus a memo of what each string parsed to.
///
/// Both halves exist for the same reason — this runs inside SwiftUI *body
/// getters*. `EpisodeRow.hasAired` parses on every layout pass, and a season
/// list re-renders on every queue tick and every hover, so the same handful of
/// air-date strings is parsed thousands of times a second.
///
///   - Formatters: `ISO8601DateFormatter` builds an ICU formatter in `init` and
///     again on every `formatOptions` / `timeZone` assignment, so the original
///     "one formatter, reconfigured four times per call" cost ~50 µs a parse.
///   - Memo: even with the formatters cached, ICU parsing (up to four attempts
///     before the date-only shape resolves) stayed at ~15 µs — still 12% of the
///     main thread on the season screen. Arr date strings are a tiny, repeating
///     set, so a dictionary hit replaces the parse entirely.
///
/// `@unchecked Sendable` + a lock: the formatters are mutable Foundation
/// objects and the memo is mutable state, while parsing runs on the decoding
/// tasks as well as the main actor. A dictionary lookup under a lock is orders
/// of magnitude cheaper than what it replaces.
private final class ArrDateParser: @unchecked Sendable {
    static let shared = ArrDateParser()

    private let lock = NSLock()
    private let zonedFractional = ISO8601DateFormatter()
    private let zoned = ISO8601DateFormatter()
    private let zoneless = ISO8601DateFormatter()
    private let dateOnly = ISO8601DateFormatter()
    /// The zone `dateOnly` is configured for — see `parse(_:)`.
    private var dateOnlyZone: TimeZone
    /// string → parsed result, misses included (a `nil` date is just as
    /// expensive to reach — it costs all four attempts).
    private var memo: [String: Date?] = [:]
    /// Flushed wholesale rather than evicted one by one: the working set is a
    /// screen's worth of dates, so the bound is only there to stop an unbounded
    /// crawl (a long history scroll) from retaining every string it ever saw.
    private static let memoLimit = 2_048

    private init() {
        zonedFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        zoned.formatOptions = [.withInternetDateTime]
        zoneless.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        zoneless.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.formatOptions = [.withFullDate]
        dateOnlyZone = Calendar.current.timeZone
        dateOnly.timeZone = dateOnlyZone
    }

    /// Order matters: `ISO8601DateFormatter` with `.withFullDate` is *lenient* —
    /// it happily accepts "2024-03-15T14:30:00" by matching the date prefix and
    /// silently discarding the time — so the zone-less date-time shape has to be
    /// tried before it, or "airs at 20:00" renders as midnight.
    func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }

        // The calendar-day shape below anchors at LOCAL midnight, and that zone
        // can change under us (an `NSTimeZone.default` override — which the
        // tests do — or the user travelling). Re-read it every call: the
        // comparison is free, and a change invalidates every memoized date-only
        // answer, so the memo goes with it.
        let zone = Calendar.current.timeZone
        if zone != dateOnlyZone {
            dateOnlyZone = zone
            dateOnly.timeZone = zone
            memo.removeAll(keepingCapacity: true)
        }

        if let hit = memo[string] { return hit }

        let parsed = parseUncached(string)
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
        memo[string] = parsed
        return parsed
    }

    private func parseUncached(_ string: String) -> Date? {
        // Well-formed ISO8601 carrying its own zone ("…Z" / "…+02:00"), with and
        // without fractional seconds. The zone in the string wins.
        if let d = zonedFractional.date(from: string) { return d }
        if let d = zoned.date(from: string) { return d }

        // Zone-less date-time ("2024-03-15T14:30:00"). Read as UTC: every arr
        // timestamp that carries a time is a UTC instant (hence Sonarr's
        // `airDateUtc`) — it just loses its "Z" when .NET serializes a DateTime
        // whose Kind is unspecified. Fractional seconds are tolerated and dropped.
        if let d = zoneless.date(from: string) { return d }

        // Date-only ("2024-03-15"). Unlike the above this is a *calendar day*,
        // not an instant, so anchor it at LOCAL midnight. Parsed as 00:00 UTC it
        // lands before local midnight for every user west of Greenwich, and the
        // Upcoming list — which filters on `Calendar.current.startOfDay(for:
        // Date())` — hid today's releases across all of the Americas.
        //
        // The zone comes from `Calendar.current`, not `TimeZone.current`: the two
        // disagree whenever `NSTimeZone.default` has been overridden, because
        // `TimeZone.current` reports the *system* zone and ignores the override
        // while `Calendar.current` honours it. Taking it from the same calendar
        // the Upcoming filter uses is what actually guarantees the two agree.
        return dateOnly.date(from: string)
    }
}

/// Non-trapping Double → Int64 for byte counts off the wire.
///
/// `Int64(someDouble)` is a *fatal error* for NaN, infinity or anything
/// outside Int64's range, and `1e300` is perfectly legal JSON — so a buggy or
/// hostile arr could kill the app just by answering a queue request. Clamp
/// into `0...Int64.max` instead; a nonsense size renders as a wrong number,
/// which beats a crash.
func clampedBytes(_ value: Double?) -> Int64 {
    // NaN fails every comparison, so `!(value > 0)` catches it here too.
    guard let value, value > 0 else { return 0 }
    // `Double(Int64.max)` rounds up to exactly 2^63, so `<` here means the
    // truncating initializer below is guaranteed to be in range. It also
    // catches `.infinity`, which clamps to the maximum like any other
    // over-large size rather than collapsing to zero — 1e300 and ∞ must not
    // land on opposite ends of the range.
    guard value < Double(Int64.max) else { return Int64.max }
    return Int64(value)
}

func parseProtocol(_ raw: String?) -> QueueItem.DownloadProtocol {
    switch raw?.lowercased() {
    case "usenet": return .usenet
    case "torrent": return .torrent
    // Lidarr serialises the .NET type name ("TorrentDownloadProtocol" /
    // "UsenetDownloadProtocol") instead of Radarr/Sonarr's plain form.
    // An unknown protocol has real consequences downstream — no download
    // client resolves for the row, so pause/resume disappear everywhere.
    case "torrentdownloadprotocol": return .torrent
    case "usenetdownloadprotocol": return .usenet
    default: return .unknown
    }
}

/// Maps an arr queue record onto our unified status. Shared by all four
/// clients, so keep it free of per-arr assumptions.
///
/// `trackedStatus` is Servarr's `trackedDownloadStatus` (ok / warning /
/// error) — its verdict on the grab as a whole — while `trackedState` is the
/// finer-grained stage. Both are needed: `status` alone stays "completed" once
/// the bytes have landed even if the import then blew up.
func parseStatus(arrStatus: String?, trackedState: String?, trackedStatus: String? = nil) -> QueueItem.Status {
    let status = arrStatus?.lowercased()
    if status == "paused" { return .paused }

    func resolve() -> QueueItem.Status {
        if let tracked = trackedState?.lowercased() {
            switch tracked {
            case "downloading": return .downloading
            // Sonarr v4 / Radarr v5 spell failure differently depending on
            // where the grab died — the transfer itself (downloadFailed /
            // downloadFailedPending / failedPending) or the import step
            // (importFailed) — plus a terminal "failed". Every one of them is
            // a dead download, not a finished one.
            case "downloadfailed", "downloadfailedpending", "failedpending", "failed", "importfailed":
                return .failed
            case "importing", "importpending": return .importing
            case "imported": return .completed
            // `ignored` = the arr deliberately stopped tracking this grab
            // (manually ignored, or a release it can't match). Not an error,
            // but not progress either.
            case "importblocked", "ignored": return .warning
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

    let resolved = resolve()
    // Backstop for state names we don't know yet: an errored grab must never
    // render as a green "Completed" pill. An unrecognised state falls through
    // to `status`, which for a finished-but-failed download is "completed" —
    // exactly the case that had users believing a failed grab had worked.
    if resolved == .completed, trackedStatus?.lowercased() == "error" { return .failed }
    return resolved
}
