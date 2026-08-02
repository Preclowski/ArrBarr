import Foundation

public actor SonarrClient: ArrAPIClient {
    public let config: ServiceConfig
    public let apiBase = "/api/v3"
    public let serviceName = "Sonarr"
    public let http = HTTPClient()

    private struct CachedEpisodeFiles { let files: [SonarrEpisodeFile]; let expiry: Date }
    private var episodeFileCache: [Int: CachedEpisodeFiles] = [:]
    /// The side-load exists to show what a download is upgrading *from*, and an
    /// existing episode file only changes when an import completes — at which
    /// point the row leaves the queue anyway. At 60s and a 30s poll, every other
    /// refresh re-fetched `/episodefile` once per series in the queue, which on
    /// a busy queue was the second-largest thing on the wire after `/queue`
    /// itself. Fifteen minutes costs a stale "upgrade from" label at worst.
    private let episodeFileCacheTTL: TimeInterval = 15 * 60

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
                // `includeSeries` is gone — see LidarrClient.fetchQueue. It was
                // the worst offender of the four: Sonarr emits one queue row per
                // expected episode in a season pack, so a 22-episode pack
                // repeated the entire series object (seasons[] with per-season
                // statistics, alternateTitles[], genres, path) 22 times. The
                // payload was quadratic in pack size.
                //
                // `includeEpisode` deliberately STAYS. It is ~400 bytes and does
                // not repeat, and what it carries is not stable-metadata: the
                // drill-down gate reads `episodeNumber`, and `episodeFileId`
                // joins the row to its on-disk file and flips the moment an
                // import lands. Moving it into the metadata store would trade a
                // large regression surface for a rounding error.
                URLQueryItem(name: "includeEpisode", value: "true"),
                URLQueryItem(name: "includeUnknownSeriesItems", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)

        let page: ArrQueuePage<SonarrQueueRecord>
        do {
            page = try JSONDecoder().decode(ArrQueuePage<SonarrQueueRecord>.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
        warnIfQueueTruncated(returned: page.records.count, totalRecords: page.totalRecords)

        let baseURL = config.baseURL
        // One `/episodefile?seriesId=` call per distinct series, but throttled
        // to `maxConcurrentSideLoads` — see that constant for why an uncapped
        // group makes the tail of a big queue time out instead of going faster.
        let seriesIds = Array(Set(page.records.compactMap { $0.series?.id ?? $0.seriesId }))
        async let metaMap = resolveSeriesMetadata(
            ids: seriesIds.filter { $0 > 0 }, baseURL: baseURL
        )
        var fileMap: [Int: SonarrEpisodeFile] = [:]
        await withTaskGroup(of: [SonarrEpisodeFile].self) { group in
            var next = 0
            while next < min(Self.maxConcurrentSideLoads, seriesIds.count) {
                let sid = seriesIds[next]
                group.addTask { (try? await self.fetchEpisodeFiles(seriesId: sid)) ?? [] }
                next += 1
            }
            // Each completion frees a slot — top the group back up so exactly
            // `maxConcurrentSideLoads` requests stay in flight until we run out.
            for await files in group {
                for f in files { fileMap[f.id] = f }
                if next < seriesIds.count {
                    let sid = seriesIds[next]
                    group.addTask { (try? await self.fetchEpisodeFiles(seriesId: sid)) ?? [] }
                    next += 1
                }
            }
        }
        let meta = await metaMap
        return page.records.map { Self.unify($0, baseURL: baseURL, fileMap: fileMap, meta: meta) }
    }

    /// Public wrapper for the cached `fetchEpisodeFiles` — returns the
    /// files keyed by `episodeFileId` so the detail view can render
    /// custom-format scores next to downloaded episode rows without
    /// firing one `/episodefile/{id}` call per episode.
    func fetchEpisodeFileMap(seriesId: Int) async throws -> [Int: SonarrEpisodeFile] {
        if DemoMode.isActive {
            return DemoMocks.sonarrEpisodeFileMap(seriesId: seriesId)
        }
        let files = try await fetchEpisodeFiles(seriesId: seriesId)
        var map: [Int: SonarrEpisodeFile] = [:]
        for f in files { map[f.id] = f }
        return map
    }

    private func resolveSeriesMetadata(ids: [Int], baseURL: String) async -> [Int: TitleMetadataStore.Metadata] {
        await resolveMetadata(ids: ids, source: .sonarr, kind: .series) { id in
            guard let detail = try? await self.fetchSeriesDetails(id: id) else { return nil }
            let (poster, auth) = (detail.images ?? []).posterURL(baseURL: baseURL)
            return TitleMetadataStore.Metadata(
                title: detail.title, year: detail.year, slug: detail.titleSlug,
                posterURL: poster, posterRequiresAuth: auth
            )
        }
    }

    private func fetchEpisodeFiles(seriesId: Int) async throws -> [SonarrEpisodeFile] {
        if let cached = episodeFileCache[seriesId], cached.expiry > Date() {
            return cached.files
        }
        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/episodefile",
            query: [URLQueryItem(name: "seriesId", value: String(seriesId))]
        )
        let data = try await http.get(url, headers: apiHeaders)
        let files = (try? JSONDecoder().decode([SonarrEpisodeFile].self, from: data)) ?? []
        episodeFileCache[seriesId] = CachedEpisodeFiles(
            files: files,
            expiry: Date().addingTimeInterval(episodeFileCacheTTL)
        )
        return files
    }

    func fetchCalendar() async throws -> [UpcomingItem] {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }

        let now = Date()
        // 30 days, same window as Radarr/Lidarr/Whisparr — a shorter one here
        // made the merged Upcoming list simply stop showing episodes two weeks
        // out while still listing movies a month out.
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]

        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/calendar",
            query: [
                URLQueryItem(name: "start", value: fmt.string(from: now)),
                URLQueryItem(name: "end", value: fmt.string(from: end)),
                URLQueryItem(name: "includeSeries", value: "true"),
                URLQueryItem(name: "unmonitored", value: "false"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)

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
            path: "\(apiBase)/history",
            query: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "pageSize", value: "50"),
                URLQueryItem(name: "sortKey", value: "date"),
                URLQueryItem(name: "sortDirection", value: "descending"),
                URLQueryItem(name: "includeSeries", value: "true"),
                URLQueryItem(name: "includeEpisode", value: "true"),
            ]
        )
        let data = try await http.get(url, headers: apiHeaders)
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

    func fetchSeriesDetails(id: Int) async throws -> SonarrSeriesDetail {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let demo = DemoMocks.sonarrSeriesDetail(id: id) { return demo }
            throw HTTPError.decoding(NSError(domain: "demo", code: 404))
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/series/\(id)")
        let data = try await http.get(url, headers: apiHeaders)
        do { return try JSONDecoder().decode(SonarrSeriesDetail.self, from: data) }
        catch { throw HTTPError.decoding(error) }
    }

    func fetchEpisodes(seriesId: Int) async throws -> [SonarrEpisodeDetail] {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return DemoMocks.sonarrEpisodes(seriesId: seriesId)
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/episode",
            query: [URLQueryItem(name: "seriesId", value: String(seriesId))]
        )
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([SonarrEpisodeDetail].self, from: data)) ?? []
    }

    /// Fetches an episode-file record. Sonarr's `/episode/{id}` returns
    /// `episodeFileId` but not the file payload; the full record (with
    /// quality / size / customFormats) lives at `/episodefile/{id}`.
    /// Used by `EpisodeDetailOverlay` to surface CF chips for on-disk
    /// episodes.
    func fetchEpisodeFile(id: Int) async throws -> ArrFile? {
        if DemoMode.isActive { return nil }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/episodefile/\(id)")
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode(ArrFile.self, from: data))
    }

    // MARK: - Search commands
    //
    // Sonarr's `/command` endpoint fires async tasks against the configured
    // indexers. Returns immediately with a commandId; the work happens in
    // the background and any matching releases land in the regular queue.
    // We don't poll commandId — the response confirms the command was
    // accepted, that's all the UI needs to flip the button back. Results
    // show up later in the Queue tab like any other download.

    func searchEpisodes(episodeIds: [Int]) async throws {
        try await postCommand([
            "name": "EpisodeSearch",
            "episodeIds": episodeIds,
        ])
    }

    func searchSeason(seriesId: Int, seasonNumber: Int) async throws {
        // Earlier iterations of this method tried two paths:
        //   - `SeasonSearch` command — silently no-op'd because the
        //     episodes inside the season were still `monitored=false`
        //   - `EpisodeSearch` with explicit ids of every aired-missing
        //     episode — worked, but flooded Sonarr's indexer queue
        //     with N parallel sequential searches, each rate-limited,
        //     producing a visible "drip" of per-episode tasks over
        //     minutes
        // Now that `setSeasonMonitored` cascades to `episode.monitored`
        // (the missing piece causing SeasonSearch to no-op), the single
        // `SeasonSearch` command is reliable AND presents as one
        // task in Sonarr's Activity tab instead of N parallel ones.
        try await postCommand([
            "name": "SeasonSearch",
            "seriesId": seriesId,
            "seasonNumber": seasonNumber,
        ])
    }

    func searchSeries(seriesId: Int) async throws {
        // SeriesSearch presents as a single Sonarr task; internally it
        // enumerates all monitored episodes across the series and fires
        // searches. Same reasoning as `searchSeason` above — much
        // cleaner UX than flooding Sonarr's queue with explicit
        // EpisodeSearch lists.
        try await postCommand([
            "name": "SeriesSearch",
            "seriesId": seriesId,
        ])
    }

    /// Toggle season monitoring. Tries the canonical V5 endpoint first
    /// (`PUT /api/v5/series/{id}/season`) — single atomic operation
    /// that Sonarr's own modern frontend uses, with the server doing
    /// the episode cascade and event dispatch internally. Falls back
    /// to the V3 two-step (`/seasonpass` + `/episode/monitor`) for
    /// older Sonarrs that haven't shipped V5 yet, so we don't regress
    /// on existing installs.
    func setSeasonMonitored(seriesId: Int, seasonNumber: Int, monitored: Bool) async throws {
        if DemoMode.isActive {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return
        }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }

        do {
            try await setSeasonMonitoredV5(seriesId: seriesId, seasonNumber: seasonNumber, monitored: monitored)
        } catch HTTPError.status(let code, _) where code == 404 || code == 405 {
            // Sonarr doesn't expose V5 yet — fall back to the V3 path.
            try await setSeasonMonitoredV3(seriesId: seriesId, seasonNumber: seasonNumber, monitored: monitored)
        }
    }

    /// V5 atomic flip — body `{seasonNumber, monitored}`. Server handles
    /// the episode cascade internally so we don't need a second
    /// request, and downstream `SeasonSearch` sees the same internal
    /// state the UI flow produces (the difference that's been letting
    /// season packs slip through in our two-step V3 approach).
    private func setSeasonMonitoredV5(seriesId: Int, seasonNumber: Int, monitored: Bool) async throws {
        let url = try http.url(base: config.baseURL, path: "/api/v5/series/\(seriesId)/season")
        let body: [String: Any] = [
            "seasonNumber": seasonNumber,
            "monitored": monitored,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await http.put(url,
                               headers: apiHeaders.merging(["Content-Type": "application/json"]) { $1 },
                               body: data)
    }

    /// V3 fallback. Mirrors what Sonarr's series-detail page does when
    /// you click a season's monitor checkbox: GET the full series
    /// record, mutate the target season's `monitored` flag in-place,
    /// PUT the modified object back. Sonarr handles the episode
    /// cascade server-side as part of `UpdateSeries`.
    ///
    /// Previous iterations tried `/seasonpass` (flip season flag) +
    /// `/episode/monitor` (manual bulk-cascade). Functionally it
    /// flipped both flags, but the bulk-cascade endpoint fires
    /// per-episode `MonitorChanged` events server-side which, for
    /// users with "Search on Monitor" enabled, results in N parallel
    /// auto-searches — each one bypassing season-pack prioritization
    /// because EpisodeSearch only matches per-episode releases. The
    /// downstream `SeasonSearch` we fire is drowned out by the noise,
    /// so the user sees 22 individual episodes downloaded instead of
    /// one season pack. The full-record PUT skips the per-episode
    /// event storm and lets `SeasonSearch` work as designed.
    private func setSeasonMonitoredV3(seriesId: Int, seasonNumber: Int, monitored: Bool) async throws {
        // CRITICAL nuance found via tester round 2: Sonarr's
        // `UpdateSeries` only runs `SetEpisodeMonitoredBySeason` (the
        // cascade that flips every episode in a season to match the
        // season's flag) when the season's `monitored` actually
        // transitions (storedSeason.Monitored != incoming.Monitored).
        // A chat command "grab S4" against an already-monitored S4
        // hits a no-op PUT → no cascade → episodes keep stale
        // per-episode state → SeasonSearch finds those and falls
        // back to per-episode releases instead of the available pack.
        //
        // Force the transition: write the *opposite* value first to
        // make Sonarr cascade once, then write the target value to
        // cascade again. Two PUTs total; intermediate state is
        // observable for ~tens of ms, acceptable for a non-hot-path
        // user-confirmed action.
        let seriesURL = try http.url(base: config.baseURL, path: "\(apiBase)/series/\(seriesId)")

        func mutateAndPut(_ value: Bool) async throws {
            let currentData = try await http.get(seriesURL, headers: apiHeaders)
            guard var series = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
                throw HTTPError.decoding(NSError(domain: "ArrBarr.Sonarr.setSeasonMonitored", code: 0))
            }
            var seasons = (series["seasons"] as? [[String: Any]]) ?? []
            var found = false
            for i in seasons.indices where (seasons[i]["seasonNumber"] as? Int) == seasonNumber {
                seasons[i]["monitored"] = value
                found = true
                break
            }
            guard found else { return }
            series["seasons"] = seasons
            let body = try JSONSerialization.data(withJSONObject: series)
            _ = try await http.put(seriesURL,
                                   headers: apiHeaders.merging(["Content-Type": "application/json"]) { $1 },
                                   body: body)
        }

        try await mutateAndPut(!monitored)
        try await mutateAndPut(monitored)
    }

    /// LLM-suggested titles surface as cards. Mirrors Sonarr's
    /// `/api/v3/series/lookup?term=…`.
    func lookupSeries(term: String) async throws -> [SonarrLookupRecord] {
        if DemoMode.isActive { return [] }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "\(apiBase)/series/lookup",
            query: [URLQueryItem(name: "term", value: term)]
        )
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([SonarrLookupRecord].self, from: data)) ?? []
    }

    func fetchAllSeries() async throws -> [SonarrLibraryRecord] {
        if DemoMode.isActive { return [] }
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)/series")
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode([SonarrLibraryRecord].self, from: data)) ?? []
    }

    private static func unifyCalendar(_ r: SonarrCalendarRecord, baseURL: String) -> UpcomingItem? {
        guard let dateStr = r.airDateUtc, let date = parseArrDate(dateStr) else { return nil }

        // Bake the year into the title so series read the same shape
        // as movies in the upcoming list ("Rick and Morty (2013)").
        // Without this, Radarr rows showed years and Sonarr rows
        // didn't — asymmetric and confusing.
        let baseSeriesTitle = r.series?.title ?? "Unknown"
        let seriesTitle = r.series?.year.map { "\(baseSeriesTitle) (\($0))" } ?? baseSeriesTitle
        var subtitle: String?
        if let s = r.seasonNumber, let e = r.episodeNumber {
            let code = String(format: "S%02dE%02d", s, e)
            if let epTitle = r.title, !epTitle.isEmpty {
                subtitle = "\(code) · \(epTitle)"
            } else {
                subtitle = code
            }
        }
        let (poster, auth) = (r.series?.images ?? []).posterURL(baseURL: baseURL)

        // Sonarr returns runtime + ratings on the series, not the episode.
        // SonarrLookupRatings.value is the IMDb score on calendar payloads —
        // Sonarr only surfaces one rating slot, distinct from Radarr's
        // multi-source ratings object.
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
            posterRequiresAuth: auth,
            imdb: r.series?.ratings?.value,
            runtime: r.series?.runtime,
            entityId: r.seriesId
        )
    }

    /// Extracts the scene-style release group suffix from a release name —
    /// the trailing `-GROUP` token after the final dash, with any file
    /// extension stripped first. Used to fingerprint per-episode releases
    /// that came from the same uploader so virtual season grouping can
    /// collapse them into one row.
    private static func parseReleaseGroup(from name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        var stripped = name
        if let dot = stripped.lastIndex(of: ".") {
            let ext = stripped[stripped.index(after: dot)...]
            // Only strip if it looks like a file extension (≤4 alphanum chars).
            if ext.count <= 4, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                stripped = String(stripped[..<dot])
            }
        }
        guard let dash = stripped.lastIndex(of: "-") else { return nil }
        let token = stripped[stripped.index(after: dash)...]
        guard !token.isEmpty,
              token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        return String(token)
    }

    /// Wire record -> `QueueItem`. Internal rather than private so
    /// `QueueUnificationTests` can pin it: this is where every displayed field
    /// on a queue row is decided, and nothing else in the suite reaches it.
    static func unify(
        _ r: SonarrQueueRecord,
        baseURL: String,
        fileMap: [Int: SonarrEpisodeFile],
        meta: [Int: TitleMetadataStore.Metadata] = [:]
    ) -> QueueItem {
        let total = clampedBytes(r.size)
        let left = clampedBytes(r.sizeleft)
        let progress: Double
        if total > 0 {
            progress = max(0, min(1, 1.0 - Double(left) / Double(total)))
        } else {
            progress = 0
        }

        // Store first, embedded series second — see `LidarrClient.unify`.
        let cached = (r.seriesId ?? r.series?.id).flatMap { meta[$0] }
        let title: String
        let subtitle: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let episodeTitle: String?
        if let s = cached ?? r.series.map({
            TitleMetadataStore.Metadata(title: $0.title, year: $0.year, slug: $0.titleSlug)
        }) {
            // Bake the year into the series title so queue rows read the
            // same "Series (2019)" shape as movies / the upcoming list.
            title = s.year.map { "\(s.title) (\($0))" } ?? s.title
            if let ep = r.episode, let season = ep.seasonNumber, let number = ep.episodeNumber {
                seasonNumber = season
                episodeNumber = number
                episodeTitle = ep.title?.isEmpty == false ? ep.title : nil
                // Unified Sonarr subtitle shape: "S02E03 · Title" — matches
                // unifyHistory and unifyCalendar so every Sonarr surface reads
                // the same way (queue rows already group under a season header,
                // so the verbose "Season XX" lead was redundant here).
                let code = String(format: "S%02dE%02d", season, number)
                subtitle = episodeTitle.map { "\(code) · \($0)" } ?? code
            } else {
                seasonNumber = nil
                episodeNumber = nil
                episodeTitle = nil
                subtitle = nil
            }
        } else {
            title = r.title ?? "Unknown"
            seasonNumber = nil
            episodeNumber = nil
            episodeTitle = nil
            subtitle = nil
        }
        var poster = cached?.posterURL
        var posterAuth = cached?.posterRequiresAuth ?? false
        if poster == nil {
            (poster, posterAuth) = (r.series?.images ?? []).posterURL(baseURL: baseURL)
        }

        let existingFile = (r.episode?.episodeFileId).flatMap { id in id > 0 ? fileMap[id] : nil }
        let isUpgrade = existingFile != nil || (r.episode?.hasFile ?? false)

        return QueueItem(
            id: "sonarr-\(r.id)",
            source: .sonarr,
            arrQueueId: r.id,
            downloadId: r.downloadId,
            downloadProtocol: parseProtocol(r.protocol),
            downloadClient: r.downloadClient,
            indexer: r.indexer,
            title: title,
            subtitle: subtitle,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            episodeTitle: episodeTitle,
            releaseName: r.title,
            status: parseStatus(arrStatus: r.status, trackedState: r.trackedDownloadState, trackedStatus: r.trackedDownloadStatus),
            progress: progress,
            sizeTotal: total,
            sizeLeft: left,
            timeLeft: r.timeleft,
            customFormats: (r.customFormats ?? []).map(\.name),
            customFormatScore: r.customFormatScore ?? 0,
            quality: r.quality?.name,
            releaseGroup: parseReleaseGroup(from: r.title),
            isUpgrade: isUpgrade,
            existingCustomFormats: (existingFile?.customFormats ?? []).map(\.name),
            existingCustomFormatScore: existingFile?.customFormatScore,
            existingQuality: existingFile?.quality?.name,
            existingSize: existingFile?.size,
            existingFileName: existingFile?.relativePath.map { URL(fileURLWithPath: $0).lastPathComponent },
            contentSlug: cached?.slug ?? r.series?.titleSlug,
            entityId: r.series?.id ?? r.seriesId,
            posterURL: poster,
            posterRequiresAuth: posterAuth,
            statusMessages: r.statusMessages.flattenToLines()
        )
    }
}
