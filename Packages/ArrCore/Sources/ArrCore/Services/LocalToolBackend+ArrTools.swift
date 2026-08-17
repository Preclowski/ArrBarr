import Foundation

// Arr-side tool implementations: per-arr search / list / calendar /
// monitor / search-episodes. Lives in an extension so the core actor
// stays focused on init + dispatch + the small generic helpers it
// shares across every tool.

extension LocalToolBackend {
    // MARK: - Tool implementations

    func searchSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearch(args: args, source: .sonarr, config: sonarr, kind: "series",
                            yearAware: true, rich: { .searchSeriesResults($0) })
    }

    func searchMovie(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearch(args: args, source: .radarr, config: radarr, kind: "movie",
                            yearAware: true, rich: { .searchMovieResults($0) })
    }

    /// Curated-recommendation tool. The LLM passes its own taste picks
    /// (title + optional year) and we resolve each through the arr's
    /// lookup endpoint so the chat surfaces rich cards (poster / ratings /
    /// in-library state) instead of a markdown list the user can't act on.
    ///
    /// Why this exists: `tmdb_discover_*` filters by genre/year/popularity
    /// and is algorithmic — it's poor for taste-based queries ("something
    /// in the mood of Mr. Robot"). The model's own training-data
    /// associations are usually better. This tool gives the model a way
    /// to *present* those picks as interactive cards.
    ///
    /// Dual-channel output: condensed text to the model (one line per
    /// pick + library state, so it knows what was actually surfaced and
    /// what couldn't be resolved), full SearchResults to the UI.
    func suggestTitles(_ args: JSONValue) async throws -> ToolCallOutput {
        let kind = Self.stringArg(args, key: "kind").lowercased()
        guard kind == "series" || kind == "movie" else {
            return ToolCallOutput(text: "suggest_titles requires kind='series' or kind='movie'.")
        }
        let items = Self.suggestItems(args)
        guard !items.isEmpty else {
            return ToolCallOutput(text: "suggest_titles needs a non-empty 'items' array of {title, year?} picks.")
        }
        // 15 used to be the cap, which was fine until libraries got deep: a
        // curated 3000-film shelf owns most of any canonical fifteen, so the
        // model had to guess again and again to accumulate a handful of unowned
        // picks. Resolving 40 in parallel is cheap; another round is not.
        let capped = Array(items.prefix(40))
        // Ownership is a fact, not a judgement, so it is safe to drop here —
        // unlike genre or mood, which stay with the model.
        let excludeOwned = Self.optionalBoolArg(args, key: "exclude_owned") ?? false

        let source: QueueItem.Source = (kind == "series") ? .sonarr : .radarr
        let config = (kind == "series") ? sonarr : radarr
        guard config.isConfigured else {
            return ToolCallOutput(text: "\(source.displayName) is not configured — can't resolve \(kind) suggestions.")
        }
        let client = SearchClient(config: config, source: source)

        // Library map fetched in parallel with the per-pick lookups. Each
        // resolved SearchResult carries its arr-side metadata id (tvdbId
        // for series, tmdbId for movies) in `.id`; we look that up in the
        // map to set `inLibraryArrId` for items the user already owns.
        // RichToolResultView reads that field to route the tap to
        // DetailView instead of SearchAddPanel — without this, cards for
        // owned series/movies surface as "add me" instead of "open me".
        async let libraryMapFetch: [Int: Int] = (kind == "series")
            ? sonarrLibraryByTVDBId()
            : radarrLibraryByTMDBId()

        // Parallel lookups — each is a single HTTP. Order in the output
        // preserves the model's curation (which is signal: a curator's
        // ordering reflects relevance), so we collect by index.
        var resolved: [(index: Int, result: SearchResult)] = []
        var missing: [(index: Int, label: String)] = []

        await withTaskGroup(of: (Int, Result<SearchResult?, Error>).self) { group in
            for (idx, item) in capped.enumerated() {
                group.addTask { [client] in
                    do {
                        let query = Self.lookupTerm(title: item.title, year: item.year, tmdbId: item.tmdbId)
                        let hits = try await Self.searchWithYearAwareness(client: client, query: query)
                        // Year-tagged match wins; otherwise top hit; otherwise nil.
                        let match = item.year.flatMap { y in hits.first(where: { $0.year == y }) }
                            ?? hits.first
                        return (idx, .success(match))
                    } catch {
                        return (idx, .failure(error))
                    }
                }
            }
            for await (idx, outcome) in group {
                switch outcome {
                case .success(let result?):
                    resolved.append((idx, result))
                case .success(nil), .failure:
                    let label = capped[idx].year.map { "\(capped[idx].title) (\($0))" } ?? capped[idx].title
                    missing.append((idx, label))
                }
            }
        }
        resolved.sort { $0.index < $1.index }
        missing.sort { $0.index < $1.index }

        let libraryMap = await libraryMapFetch
        // Tag any resolved card that maps to an arr library record. .id
        // is tvdbId for series / tmdbId for movies — matches the library
        // map's keys exactly.
        let tagged = resolved.map { entry -> SearchResult in
            guard let arrId = libraryMap[entry.result.externalId] else { return entry.result }
            return entry.result.withInLibraryArrId(arrId)
        }
        let results = excludeOwned ? tagged.filter { $0.inLibraryArrId == nil } : tagged
        let droppedAsOwned = tagged.count - results.count
        var text = Self.formatSuggestionsCondensed(
            resolved: results,
            missing: missing.map { $0.label },
            kind: kind
        )
        if droppedAsOwned > 0 {
            text += "\n\(droppedAsOwned) pick\(droppedAsOwned == 1 ? " was" : "s were") dropped as already in the library."
        }
        let rich: ChatRichContent = (kind == "series") ? .searchSeriesResults(results) : .searchMovieResults(results)
        return ToolCallOutput(text: text, rich: rich)
    }

    /// Aggregated health check across every configured arr. Each arr's
    /// `/health` endpoint returns the warnings + errors its own UI shows in
    /// the bell icon — disconnected indexers, missing root folders, full
    /// disk, etc. The model gets a per-arr one-line summary; full-detail
    /// messages are inlined only when there's something to report so the
    /// output stays compact when everything's green.
    func healthCheck() async throws -> ToolCallOutput {
        let configured: [(QueueItem.Source, ServiceConfig)] = [
            (.sonarr, sonarr), (.radarr, radarr),
            (.lidarr, lidarr), (.whisparr, whisparr),
        ].filter { $0.1.isConfigured }

        let clientLines = await downloadClientHealthLines()

        guard !configured.isEmpty else {
            // No arrs, but download clients might still be set up.
            if clientLines.isEmpty {
                return ToolCallOutput(text: "No services are configured.")
            }
            return ToolCallOutput(text: (["Download clients:"] + clientLines).joined(separator: "\n"))
        }

        // Each fetch is one HTTP — fan out in parallel.
        var report: [(source: QueueItem.Source, records: [ArrHealthRecord], error: String?)] = []
        await withTaskGroup(of: (QueueItem.Source, Result<[ArrHealthRecord], Error>).self) { group in
            for (source, cfg) in configured {
                group.addTask { [cfg] in
                    do {
                        let records: [ArrHealthRecord]
                        switch source {
                        case .sonarr:   records = try await SonarrClient(config: cfg).fetchHealth()
                        case .radarr:   records = try await RadarrClient(config: cfg).fetchHealth()
                        case .lidarr:   records = try await LidarrClient(config: cfg).fetchHealth()
                        case .whisparr: records = try await WhisparrClient(config: cfg).fetchHealth()
                        }
                        return (source, .success(records))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, outcome) in group {
                switch outcome {
                case .success(let records):
                    report.append((source, records, nil))
                case .failure(let err):
                    report.append((source, [], err.localizedDescription))
                }
            }
        }
        report.sort { $0.source.displayName < $1.source.displayName }

        var lines: [String] = []
        for entry in report {
            if let err = entry.error {
                lines.append("\(entry.source.displayName): unreachable — \(err)")
                continue
            }
            if entry.records.isEmpty {
                lines.append("\(entry.source.displayName): healthy")
                continue
            }
            let errorCount = entry.records.filter { ($0.type ?? "").lowercased() == "error" }.count
            let warningCount = entry.records.count - errorCount
            var summary = "\(entry.source.displayName): "
            if errorCount > 0 { summary += "\(errorCount) error\(errorCount == 1 ? "" : "s")" }
            if warningCount > 0 {
                if errorCount > 0 { summary += ", " }
                summary += "\(warningCount) warning\(warningCount == 1 ? "" : "s")"
            }
            lines.append(summary)
            // Inline each message so the model has enough detail to relay.
            for rec in entry.records {
                let kind = (rec.type ?? "info").lowercased()
                let msg = rec.message ?? "(no message)"
                lines.append("  • [\(kind)] \(msg)")
            }
        }
        if !clientLines.isEmpty {
            lines.append("Download clients:")
            lines.append(contentsOf: clientLines)
        }
        return ToolCallOutput(text: lines.joined(separator: "\n"))
    }

    /// Probe every configured download client's connection in parallel.
    /// `testConnection()` returns a version/status string on success or
    /// throws when unreachable / auth-failed. Returns one summary line per
    /// configured client; empty array when none are set up.
    private func downloadClientHealthLines() async -> [String] {
        let dc = downloadClients
        let probes: [(String, DownloadClientKind, ServiceConfig)] = [
            ("qBittorrent", .qbittorrent, dc.qbittorrent),
            ("Transmission", .transmission, dc.transmission),
            ("NZBGet", .nzbget, dc.nzbget),
            ("SABnzbd", .sabnzbd, dc.sabnzbd),
            ("rTorrent", .rtorrent, dc.rtorrent),
            ("Deluge", .deluge, dc.deluge),
        ].filter { $0.2.isConfigured }

        guard !probes.isEmpty else { return [] }

        var results: [(String, String)] = []
        await withTaskGroup(of: (String, String).self) { group in
            for (label, kind, cfg) in probes {
                group.addTask { [cfg] in
                    do {
                        let status = try await Self.probeDownloadClient(kind, cfg)
                        let detail = status.isEmpty ? "" : " (\(status))"
                        return (label, "reachable\(detail)")
                    } catch {
                        return (label, "unreachable — \(error.localizedDescription)")
                    }
                }
            }
            for await r in group { results.append(r) }
        }
        results.sort { $0.0 < $1.0 }
        return results.map { "  • \($0.0): \($0.1)" }
    }

    private static func probeDownloadClient(_ kind: DownloadClientKind, _ cfg: ServiceConfig) async throws -> String {
        // qBittorrent and Deluge authenticate with a session cookie, so when
        // they aren't handed a URLSession they build their own — and a
        // URLSession keeps *itself* alive until it is invalidated. `health` is
        // read-only, so it isn't behind the destructive-tool gate and an MCP
        // client is free to poll it every 30s; letting those two clients own
        // their sessions stranded one apiece per call, cookie jar and delegate
        // queue included. Own the session here and tear it down on the way out.
        // The other four run on `URLSession.shared` and have nothing to leak.
        let cookieSession = Self.cookieSession(for: kind)
        defer { cookieSession?.finishTasksAndInvalidate() }
        switch kind {
        case .qbittorrent:  return try await QbittorrentClient(config: cfg, session: cookieSession).testConnection()
        case .transmission: return try await TransmissionClient(config: cfg).testConnection()
        case .nzbget:       return try await NzbgetClient(config: cfg).testConnection()
        case .sabnzbd:      return try await SabnzbdClient(config: cfg).testConnection()
        case .rtorrent:     return try await RtorrentClient(config: cfg).testConnection()
        case .deluge:       return try await DelugeClient(config: cfg, session: cookieSession).testConnection()
        }
    }

    /// A throwaway session with private cookie storage for the two clients that
    /// log in with a cookie, nil for the rest. Per-probe rather than one shared
    /// jar: qBittorrent's SID and Deluge's session cookie would otherwise share
    /// storage whenever both live on the same host.
    private static func cookieSession(for kind: DownloadClientKind) -> URLSession? {
        switch kind {
        case .qbittorrent, .deluge:
            let cfg = HTTPClient.uncachedConfiguration()
            cfg.httpCookieStorage = HTTPCookieStorage()
            cfg.httpCookieAcceptPolicy = .always
            cfg.httpShouldSetCookies = true
            return URLSession(configuration: cfg)
        case .transmission, .nzbget, .sabnzbd, .rtorrent:
            return nil
        }
    }

    // MARK: - Lifecycle control tools (monitor + search)

    /// Flip season monitoring. When enabling, ALWAYS fire a SeasonSearch
    /// right after — chat callers say things like "pobierz mi 3 sezon"
    /// or "monitor S3 of X" and they expect the download to start.
    /// We don't expose an opt-out for the search part: the previous
    /// `alsoSearch` arg let the model default it to false and tell the
    /// user "search queued" anyway. Now there's no override, and the
    /// result text reports the actual outcome of each step so the model
    /// can't fabricate success.
    func sonarrMonitorSeason(_ args: JSONValue) async throws -> ToolCallOutput {
        let seriesId = Self.intArg(args, key: "seriesId")
        // Accept either a `seasonNumbers` array (multi) or a legacy
        // single `seasonNumber`. Chat requests like "pobierz 10 i 11
        // sezon" name MORE THAN ONE season; the old single-int schema
        // silently dropped every season past the first. Sonarr's
        // SeasonSearch command is per-season, so we loop one call each.
        var seasons = Self.intArrayArg(args, key: "seasonNumbers")
        if seasons.isEmpty, let single = Self.optionalIntArg(args, key: "seasonNumber") {
            seasons = [single]
        }
        seasons = Array(Set(seasons)).sorted()
        guard !seasons.isEmpty else {
            return ToolCallOutput(text: "Need seasonNumbers (non-empty integer array) or a single seasonNumber.")
        }
        let state = Self.optionalBoolArg(args, key: "state") ?? true
        guard seriesId > 0 else {
            return ToolCallOutput(text: "Need a valid seriesId — run sonarr_get_series to resolve it.")
        }
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        let client = SonarrClient(config: sonarr)

        func list(_ xs: [Int]) -> String { xs.map(String.init).joined(separator: ", ") }

        // Step 1: flip monitoring on each season, recording per-season
        // success so a single rejected season doesn't sink the rest.
        var monitored: [Int] = []
        var monitorFailed: [Int] = []
        var lastMonitorError = ""
        for s in seasons {
            do {
                try await client.setSeasonMonitored(seriesId: seriesId, seasonNumber: s, monitored: state)
                monitored.append(s)
            } catch {
                monitorFailed.append(s)
                lastMonitorError = error.localizedDescription
            }
        }

        guard state else {
            if monitorFailed.isEmpty {
                return ToolCallOutput(text: "OK: stopped monitoring season(s) \(list(monitored)) of seriesId=\(seriesId). No search triggered.")
            }
            if monitored.isEmpty {
                return ToolCallOutput(text: "FAILED to stop monitoring season(s) \(list(monitorFailed)): \(lastMonitorError).")
            }
            return ToolCallOutput(text: "PARTIAL: stopped monitoring season(s) \(list(monitored)); FAILED for \(list(monitorFailed)) (\(lastMonitorError)). No search triggered.")
        }

        // Step 2: fire a SeasonSearch for each season that's now
        // monitored. Report the actual per-season outcome explicitly so
        // the model can't paper over a partial failure.
        var searched: [Int] = []
        var searchFailed: [Int] = []
        var lastSearchError = ""
        for s in monitored {
            do {
                try await client.searchSeason(seriesId: seriesId, seasonNumber: s)
                searched.append(s)
            } catch {
                searchFailed.append(s)
                lastSearchError = error.localizedDescription
            }
        }

        if monitorFailed.isEmpty && searchFailed.isEmpty {
            return ToolCallOutput(text: "OK: season(s) \(list(searched)) of seriesId=\(seriesId) now monitored, and a SeasonSearch command was POST'd to Sonarr for each. Indexer results will land in the queue when releases match — typically within ~30 seconds, longer if indexers are slow.")
        }

        var parts: [String] = []
        if !searched.isEmpty { parts.append("monitored + searching season(s) \(list(searched))") }
        if !searchFailed.isEmpty { parts.append("monitored but Sonarr REJECTED the search for season(s) \(list(searchFailed)) (\(lastSearchError))") }
        if !monitorFailed.isEmpty { parts.append("FAILED to even monitor season(s) \(list(monitorFailed)) (\(lastMonitorError))") }
        return ToolCallOutput(text: "PARTIAL: " + parts.joined(separator: "; ") + ". Tell the user EXACTLY which seasons worked and which didn't — do not claim full success. For rejected searches they should retry shortly or use the season's search button in DetailView. DO NOT call sonarr_search_episodes as a workaround — it grabs per-episode releases instead of a season pack.")
    }

    /// Manual indexer search for one or more episodes by id. Mirrors
    /// the UI's per-episode magnifying-glass action.
    func sonarrSearchEpisodesTool(_ args: JSONValue) async throws -> ToolCallOutput {
        let ids = Self.intArrayArg(args, key: "episodeIds")
        guard !ids.isEmpty else {
            return ToolCallOutput(text: "Need episodeIds (non-empty integer array).")
        }
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        do {
            try await SonarrClient(config: sonarr).searchEpisodes(episodeIds: ids)
            return ToolCallOutput(text: "Queued search for \(ids.count) episode\(ids.count == 1 ? "" : "s").")
        } catch {
            return ToolCallOutput(text: "Couldn't queue search: \(error.localizedDescription)")
        }
    }

    /// Force a Radarr indexer search for one movie. Useful for retry /
    /// upgrade prompts ("this stuck, try again", "try to grab a better
    /// quality"). Radarr's monitored flag isn't changed.
    func radarrSearchMovieTool(_ args: JSONValue) async throws -> ToolCallOutput {
        let movieId = Self.intArg(args, key: "movieId")
        guard movieId > 0 else {
            return ToolCallOutput(text: "Need a valid movieId — run radarr_get_movies to resolve it.")
        }
        guard radarr.isConfigured else {
            return ToolCallOutput(text: "Radarr is not configured.")
        }
        do {
            try await RadarrClient(config: radarr).searchMovie(movieId: movieId)
            return ToolCallOutput(text: "Search queued. Indexers will report back into the regular queue.")
        } catch {
            return ToolCallOutput(text: "Couldn't queue search: \(error.localizedDescription)")
        }
    }

    /// List albums by artistId, optionally filtered by `albumType`
    /// (Album / Single / EP / Live / Compilation / Soundtrack / Other).
    /// Compact text per album: `id, title, type, year, monitored,
    /// have/total tracks`. Capped to 40 to keep output bounded for
    /// prolific artists; trailing note tells the model how many were
    /// dropped.
    func lidarrGetArtistAlbums(_ args: JSONValue) async throws -> ToolCallOutput {
        let artistId = Self.intArg(args, key: "artistId")
        guard artistId > 0 else {
            return ToolCallOutput(text: "Need a valid artistId — run lidarr_get_artists to resolve it.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let typeFilter = Self.stringArg(args, key: "albumType").lowercased()
        let albums: [LidarrAlbumListRecord]
        do {
            albums = try await LidarrClient(config: lidarr).fetchArtistAlbums(artistId: artistId)
        } catch {
            return ToolCallOutput(text: "Lidarr fetch failed: \(error.localizedDescription)")
        }
        let filtered = albums.filter { rec in
            guard !typeFilter.isEmpty else { return true }
            return (rec.albumType ?? "").lowercased() == typeFilter
        }
        guard !filtered.isEmpty else {
            return ToolCallOutput(text: typeFilter.isEmpty
                ? "No albums found for artistId=\(artistId)."
                : "No \(typeFilter) albums found for artistId=\(artistId).")
        }
        let cap = 40
        let shown = filtered.prefix(cap)
        let lines = shown.map { rec -> String in
            let year = Self.yearFromReleaseDate(rec.releaseDate)
            let typePart = rec.albumType.map { " · \($0)" } ?? ""
            let yearPart = year.map { " (\($0))" } ?? ""
            let mon = (rec.monitored ?? false) ? "✓" : "✗"
            let have = rec.statistics?.trackFileCount ?? 0
            let total = rec.statistics?.totalTrackCount ?? rec.statistics?.trackCount ?? 0
            return "• albumId=\(rec.id) · \(rec.title)\(yearPart)\(typePart) · \(mon) \(have)/\(total) tracks"
        }
        // Name the artist, don't just echo the id back. An id-only header
        // ("Artist 1 has 36 albums") is unverifiable: if the id was wrong, the
        // model can't tell, and its only recovery is to start guessing again.
        let name = await artistName(id: artistId)
        let who = name.map { "\($0) (artistId=\(artistId))" } ?? "artistId=\(artistId)"
        var out = "\(who) has \(filtered.count) album\(filtered.count == 1 ? "" : "s")"
        if !typeFilter.isEmpty { out += " (type=\(typeFilter))" }
        out += ":\n" + lines.joined(separator: "\n")
        if filtered.count > cap {
            out += "\n(\(filtered.count - cap) more not shown — narrow with albumType to see them all.)"
        }
        // Same cards the rest of the chat gets, for the one library the chat
        // could only answer in prose. Covers come from Lidarr, so the shown
        // slice is what the rail renders — no second fetch.
        let cards = shown.map { rec in
            ChatAlbum(
                id: rec.id,
                title: rec.title,
                year: Self.yearFromReleaseDate(rec.releaseDate),
                albumType: rec.albumType,
                monitored: rec.monitored ?? false,
                trackFileCount: rec.statistics?.trackFileCount ?? 0,
                trackCount: rec.statistics?.totalTrackCount ?? rec.statistics?.trackCount ?? 0,
                images: rec.images ?? []
            )
        }
        return ToolCallOutput(text: out, rich: .albums(artist: name, albums: Array(cards)))
    }

    /// Name for a Lidarr artist id — best effort, purely so the albums answer
    /// can say whose albums these are.
    private func artistName(id: Int) async -> String? {
        guard let artists = try? await LidarrClient(config: lidarr).fetchAllArtists() else { return nil }
        return artists.first { $0.id == id }?.artistName
    }

    /// Helper: extract YYYY from an ISO-ish release date.
    static func yearFromReleaseDate(_ raw: String?) -> Int? {
        guard let raw, raw.count >= 4 else { return nil }
        return Int(raw.prefix(4))
    }

    /// Mirror of `sonarrMonitorSeason`: when state=true we ALWAYS fire
    /// the search. No opt-out arg — same reasoning, chat 'monitor album'
    /// requests always mean 'monitor and grab'.
    func lidarrMonitorAlbum(_ args: JSONValue) async throws -> ToolCallOutput {
        let albumId = Self.intArg(args, key: "albumId")
        guard albumId > 0 else {
            return ToolCallOutput(text: "Need a valid albumId — run lidarr_get_artist_albums to resolve it.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let state = Self.optionalBoolArg(args, key: "state") ?? true
        let client = LidarrClient(config: lidarr)
        do {
            try await client.setAlbumMonitored(albumId: albumId, monitored: state)
        } catch {
            return ToolCallOutput(text: "FAILED to update monitoring: \(error.localizedDescription)")
        }
        guard state else {
            return ToolCallOutput(text: "OK: stopped monitoring albumId=\(albumId). No search triggered.")
        }
        do {
            try await client.searchAlbum(albumId: albumId)
            return ToolCallOutput(text: "OK: albumId=\(albumId) is now monitored, and AlbumSearch command was POST'd to Lidarr. Indexer results will land in the queue when releases match.")
        } catch {
            return ToolCallOutput(text: "PARTIAL: monitoring on, but search FAILED: \(error.localizedDescription). Tell the user the album is monitored but they need to manually search.")
        }
    }

    /// Standalone search trigger — same as the search component of
    /// `lidarr_monitor_album(state: true)` but no monitoring flip.
    func lidarrSearchAlbumTool(_ args: JSONValue) async throws -> ToolCallOutput {
        let albumId = Self.intArg(args, key: "albumId")
        guard albumId > 0 else {
            return ToolCallOutput(text: "Need a valid albumId.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        do {
            try await LidarrClient(config: lidarr).searchAlbum(albumId: albumId)
            return ToolCallOutput(text: "Search queued for album \(albumId).")
        } catch {
            return ToolCallOutput(text: "Couldn't queue search: \(error.localizedDescription)")
        }
    }

    /// Pull `items: [{title, year?, tmdbId?}]` out of the JSON-RPC arguments.
    /// Permissive — drops malformed entries silently so a model that
    /// fumbles one item doesn't kill the whole call.
    static func suggestItems(_ value: JSONValue) -> [(title: String, year: Int?, tmdbId: Int?, reason: String?)] {
        guard case .object(let dict) = value, case .array(let arr) = dict["items"] else { return [] }
        func intValue(_ raw: JSONValue?) -> Int? {
            switch raw {
            case .number(let n): return Int(n)
            case .string(let s): return Int(s)
            default: return nil
            }
        }
        return arr.compactMap { entry -> (String, Int?, Int?, String?)? in
            guard case .object(let obj) = entry,
                  case .string(let title) = obj["title"],
                  !title.isEmpty else { return nil }
            let reason: String? = {
                if case .string(let r) = obj["reason"], !r.isEmpty { return r }
                return nil
            }()
            return (title, intValue(obj["year"]), intValue(obj["tmdbId"]), reason)
        }
    }

    /// The lookup term for one pick: an exact `tmdb:` ref when the model
    /// supplied the id (one exact hit, no wrong-remake risk — both arrs
    /// resolve it), else title-plus-year prose.
    static func lookupTerm(title: String, year: Int?, tmdbId: Int?) -> String {
        if let tmdbId { return "tmdb:\(tmdbId)" }
        return year.map { "\(title) \($0)" } ?? title
    }

    /// Condensed text for the model: surfaced picks + library state +
    /// missing labels. Kept under ~300 tokens for 15 items so it doesn't
    /// eat the local LLM's context window.
    static func formatSuggestionsCondensed(
        resolved: [SearchResult],
        missing: [String],
        kind: String
    ) -> String {
        if resolved.isEmpty && missing.isEmpty {
            return "No suggestions to surface."
        }
        var out: [String] = []
        if !resolved.isEmpty {
            let lines = resolved.map { r -> String in
                let yearPart = r.year.map { " (\($0))" } ?? ""
                // Watch state rides along with ownership — the media server
                // only knows titles that are on the shelf, so an unowned pick
                // never carries a marker either way.
                let watched = MediaServerIndex.shared.isWatched(r.mediaServerKeys) ? ", watched" : ""
                let state = (r.inLibraryArrId != nil) ? " [in library\(watched)]" : ""
                return "• \(r.title)\(yearPart)\(state)"
            }
            out.append("Surfaced \(resolved.count) \(kind) card\(resolved.count == 1 ? "" : "s") in the chat:")
            out.append(lines.joined(separator: "\n"))
        }
        if !missing.isEmpty {
            out.append("Couldn't resolve: \(missing.joined(separator: ", ")).")
        }
        return out.joined(separator: "\n")
    }

    /// Detect a 4-digit year in the query and surface year-matching hits to
    /// the top of the result list. Helps when TMDB's popularity ranking
    /// buries upcoming / niche entries under same-titled hits from years ago.
    static func searchWithYearAwareness(client: SearchClient, query: String) async throws -> [SearchResult] {
        let primary = try await client.lookup(query: query)
        guard let year = extractYear(from: query) else { return primary }
        // If we already have year-matching hits in the primary list, surface them.
        let matched = primary.filter { $0.year == year }
        let rest = primary.filter { $0.year != year }
        if !matched.isEmpty {
            return matched + rest
        }
        // Year wasn't found in the year-tagged search. Re-query without the
        // year so TMDB's lookup has a cleaner term, then filter by year.
        let bareQuery = query
            .replacingOccurrences(of: String(year), with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()[]-,"))
        guard bareQuery != query, !bareQuery.isEmpty else { return primary }
        let secondary = try await client.lookup(query: bareQuery)
        let secondaryYear = secondary.filter { $0.year == year }
        // Merge: year-matching from broader search first, then everything else.
        // Keyed on row identity, not the foreign key: a TMDB-sourced series
        // has no foreign key yet, so every one of them used to look like the
        // same row and all but the first were dropped.
        var seen = Set<String>()
        var merged: [SearchResult] = []
        for r in secondaryYear + primary + secondary where seen.insert(r.id).inserted {
            merged.append(r)
        }
        return merged
    }

    static func extractYear(from query: String) -> Int? {
        // Look for any 4-digit run that's a plausible year (1900..currentYear+5).
        let now = Calendar.current.component(.year, from: Date())
        guard let regex = try? NSRegularExpression(pattern: #"\b(19|20)\d{2}\b"#) else { return nil }
        let ns = query as NSString
        let matches = regex.matches(in: query, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if let year = Int(ns.substring(with: m.range)), year <= now + 5 {
                return year
            }
        }
        return nil
    }

    /// Render the per-season slice for `sonarr_get_series` output. With
    /// no filter it shows a condensed strip ("S1 ✓ 10/10, S2 ✓ 8/10, S3
    /// ✗ 0/0 upcoming") capped to keep tokens sane. With a filter it
    /// drops to a single targeted line. Empty when the record has no
    /// season data (shouldn't happen for live Sonarr, possible in demo).
    static func seasonsSummary(for rec: SonarrLibraryRecord, filter: Int?) -> String {
        let seasons = rec.seasons?.filter { $0.seasonNumber > 0 } ?? []
        guard !seasons.isEmpty else { return "" }
        if let target = filter {
            guard let s = seasons.first(where: { $0.seasonNumber == target }) else {
                return " · S\(target): not found in record"
            }
            return " · " + Self.formatSeasonLine(s)
        }
        // Cap to first 12 to keep the output compact for long-running shows.
        let shown = seasons.prefix(12).map(Self.formatSeasonLine).joined(separator: ", ")
        let trailing = seasons.count > 12 ? ", …" : ""
        return " · seasons: \(shown)\(trailing)"
    }

    static func formatSeasonLine(_ s: SonarrLibrarySeason) -> String {
        let mon = (s.monitored ?? false) ? "✓" : "✗"
        let have = s.statistics?.episodeFileCount ?? 0
        let total = s.statistics?.totalEpisodeCount ?? s.statistics?.episodeCount ?? 0
        return "S\(s.seasonNumber) \(mon) \(have)/\(total)"
    }

    /// Unified calendar across every configured arr (or one, via the
    /// optional `service` arg). Replaces the four per-arr calendar tools —
    /// fans out the fetches in parallel, merges, sorts by air date.
    func getCalendar(_ args: JSONValue) async throws -> ToolCallOutput {
        let requested = Self.stringArg(args, key: "service").lowercased()

        // Resolve which (source, config) pairs to query. Whisparr only
        // participates when the AI-access toggle is on (matches the guard
        // every other whisparr tool uses).
        let all: [(QueueItem.Source, ServiceConfig)] = [
            (.sonarr, sonarr), (.radarr, radarr),
            (.lidarr, lidarr), (.whisparr, whisparr),
        ]
        let targets: [(QueueItem.Source, ServiceConfig)]
        if !requested.isEmpty {
            guard let src = QueueItem.Source(rawValue: requested) else {
                return ToolCallOutput(text: "Unknown service '\(requested)'. Use sonarr, radarr, lidarr or whisparr.")
            }
            if src == .whisparr && !aiKnowsAboutWhisparr {
                return ToolCallOutput(text: "Whisparr AI access is disabled in Settings.")
            }
            guard let cfg = all.first(where: { $0.0 == src })?.1 else {
                return ToolCallOutput(text: "Unknown service '\(requested)'. Use sonarr, radarr, lidarr or whisparr.")
            }
            guard cfg.isConfigured else {
                return ToolCallOutput(text: "\(src.displayName) is not configured.")
            }
            targets = [(src, cfg)]
        } else {
            targets = all.filter { src, cfg in
                cfg.isConfigured && (src != .whisparr || aiKnowsAboutWhisparr)
            }
        }
        guard !targets.isEmpty else {
            return ToolCallOutput(text: "No services are configured.")
        }

        var merged: [UpcomingItem] = []
        var failures: [String] = []
        await withTaskGroup(of: (QueueItem.Source, Result<[UpcomingItem], Error>).self) { group in
            for (source, cfg) in targets {
                group.addTask { [cfg] in
                    do { return (source, .success(try await Self.fetchCalendar(source, cfg))) }
                    catch { return (source, .failure(error)) }
                }
            }
            for await (source, outcome) in group {
                switch outcome {
                case .success(let items): merged.append(contentsOf: items)
                case .failure(let err): failures.append("\(source.displayName) calendar unreachable — \(err.localizedDescription)")
                }
            }
        }
        merged.sort { $0.airDate < $1.airDate }

        var text = Self.formatCalendarCondensed(merged)
        if !failures.isEmpty {
            text += "\n" + failures.map { "⚠️ \($0)" }.joined(separator: "\n")
        }
        return ToolCallOutput(text: text, rich: .calendar(merged))
    }

    private static func fetchCalendar(_ source: QueueItem.Source, _ cfg: ServiceConfig) async throws -> [UpcomingItem] {
        switch source {
        case .sonarr:   return try await SonarrClient(config: cfg).fetchCalendar()
        case .radarr:   return try await RadarrClient(config: cfg).fetchCalendar()
        case .lidarr:   return try await LidarrClient(config: cfg).fetchCalendar()
        case .whisparr: return try await WhisparrClient(config: cfg).fetchCalendar()
        }
    }

    // MARK: - Lidarr tool implementations

    func searchArtist(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearchArtist(args: args)
    }

    func listArtists(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runLibraryList(
            args: args, source: .lidarr, config: lidarr,
            itemNounSingular: "artist", itemNounPlural: "artists",
            fetch: { try await LidarrClient(config: self.lidarr).fetchAllArtists() },
            filterMatch: { rec, q in (rec.artistName ?? "").lowercased().contains(q) },
            line: { r in
                let name = r.artistName ?? "(untitled)"
                // artistId FIRST, and unmissable: `lidarr_get_artist_albums`
                // requires it, and this is the only tool that can supply it.
                // While these rows printed just the MusicBrainz foreignArtistId,
                // the model had no way to satisfy that requirement — so it
                // guessed small integers, got some other artist's albums, and
                // spiralled trying to reconcile the mismatch.
                let ids = [r.id.map { "artistId=\($0)" }, r.foreignArtistId.map { "foreignArtistId=\($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
                let albumCount = r.statistics?.albumCount.map { " · \($0) album\($0 == 1 ? "" : "s")" } ?? ""
                return "• \(name)\(ids.isEmpty ? "" : " · " + ids)\(albumCount)"
            },
            rich: { .libraryArtists($0) }
        )
    }

    // MARK: - Whisparr tool implementations

    func searchScene(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearch(args: args, source: .whisparr, config: whisparr, kind: "scene",
                            yearAware: false, rich: { .searchSceneResults($0) })
    }

    func listScenes(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runLibraryList(
            args: args, source: .whisparr, config: whisparr,
            itemNounSingular: "scene", itemNounPlural: "scenes",
            fetch: { try await WhisparrClient(config: self.whisparr).fetchAllMovies() },
            filterMatch: { rec, q in (rec.title ?? "").lowercased().contains(q) },
            line: { r in
                let title = r.title ?? "(untitled)"
                let yearPart = r.year.map { " (\($0))" } ?? ""
                let fileMark = (r.hasFile ?? false) ? " · downloaded" : " · missing"
                return "• \(title)\(yearPart)\(fileMark)"
            },
            rich: { .libraryScenes($0) }
        )
    }

    static func formatCalendarCondensed(_ items: [UpcomingItem]) -> String {
        guard !items.isEmpty else { return "Nothing upcoming." }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let top = items.prefix(15)
        let lines = top.map { it -> String in
            let dateStr = fmt.string(from: it.airDate)
            if let subtitle = it.subtitle, !subtitle.isEmpty {
                return "• \(dateStr) — \(it.title) · \(subtitle)"
            }
            return "• \(dateStr) — \(it.title)"
        }
        var out = "Upcoming releases:"
        out += "\n" + lines.joined(separator: "\n")
        if items.count > top.count {
            out += "\n(\(items.count - top.count) more not shown)"
        }
        return out
    }

    // MARK: - Download queue

    /// Lists the active download queue across every configured arr. Items
    /// already carry both the incoming release's quality/format metadata AND
    /// the existing library file's (`existing*` fields, populated during queue
    /// unification), so the model gets everything it needs to explain an
    /// upgrade in a single call — no extra API round-trips beyond
    /// `fetchQueue()`.
    ///
    /// Sonarr and Radarr used to be the whole list, which meant a Lidarr
    /// download was missing from an answer that read as complete — the popover
    /// aggregates all four, so the tool disagreeing with the UI is worse than
    /// it sounds. Whisparr rides the same `aiKnowsAboutWhisparr` gate as its
    /// own tools: an arr the user hid from the model must not leak back in via
    /// a queue listing.
    func listDownloadQueue(_ args: JSONValue) async throws -> ToolCallOutput {
        let configured: [(QueueItem.Source, ServiceConfig)] = [
            (.sonarr, sonarr), (.radarr, radarr), (.lidarr, lidarr),
            (.whisparr, aiKnowsAboutWhisparr ? whisparr : .empty),
        ].filter { $0.1.isConfigured }

        guard !configured.isEmpty else {
            return ToolCallOutput(text: "No arr is configured.")
        }

        // One HTTP per arr — fan out in parallel, tolerate one side failing.
        var items: [QueueItem] = []
        var failures: [String] = []
        await withTaskGroup(of: (QueueItem.Source, Result<[QueueItem], Error>).self) { group in
            for (source, cfg) in configured {
                group.addTask { [cfg] in
                    do {
                        let queue: [QueueItem]
                        switch source {
                        case .sonarr:   queue = try await SonarrClient(config: cfg).fetchQueue()
                        case .radarr:   queue = try await RadarrClient(config: cfg).fetchQueue()
                        case .lidarr:   queue = try await LidarrClient(config: cfg).fetchQueue()
                        case .whisparr: queue = try await WhisparrClient(config: cfg).fetchQueue()
                        }
                        return (source, .success(queue))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, outcome) in group {
                switch outcome {
                case .success(let queue): items.append(contentsOf: queue)
                case .failure(let err):
                    failures.append("\(source.displayName) queue unreachable — \(err.localizedDescription)")
                }
            }
        }

        let filter = Self.stringArg(args, key: "query").lowercased()
        if !filter.isEmpty {
            items = items.filter { $0.title.lowercased().contains(filter) }
        }
        // Stable order: upgrades first, then by title.
        items.sort { lhs, rhs in
            if lhs.isUpgrade != rhs.isUpgrade { return lhs.isUpgrade }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let text = Self.formatQueueCondensed(items, failures: failures)
        return ToolCallOutput(text: text, rich: .downloadQueue(items))
    }

    /// Pure, unit-tested formatter: one line per queue item, with an
    /// `UPGRADE: old → new` diff fragment for upgrade rows.
    static func formatQueueCondensed(_ items: [QueueItem], failures: [String] = []) -> String {
        var sections: [String] = []

        if items.isEmpty {
            sections.append(failures.isEmpty
                ? "Nothing is downloading right now."
                : "Nothing is downloading right now (some services were unreachable).")
        } else {
            let top = items.prefix(25)
            var lines: [String] = []
            for item in top {
                let pct = Int((item.progress * 100).rounded())
                let tag = item.source == .sonarr ? "[Sonarr]" : "[Radarr]"
                var line = "• \(tag) \(item.title) — \(item.status.displayName) \(pct)%"
                if item.isUpgrade, let diff = upgradeDiffFragment(item) {
                    line += "\n    \(diff)"
                }
                lines.append(line)
            }
            var out = "Download queue — \(items.count) item\(items.count == 1 ? "" : "s"):"
            out += "\n" + lines.joined(separator: "\n")
            if items.count > top.count {
                out += "\n(\(items.count - top.count) more not shown)"
            }
            sections.append(out)
        }

        if !failures.isEmpty {
            sections.append(failures.map { "⚠️ \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Builds the `UPGRADE: 1080p → 2160p · score 50→120 · +DV -X · 8.1GB→24.3GB`
    /// fragment for an upgrade row. Returns nil if there's no meaningful diff.
    static func upgradeDiffFragment(_ item: QueueItem) -> String? {
        var parts: [String] = []

        let oldQ = item.existingQuality ?? "?"
        let newQ = item.quality ?? "?"
        if oldQ != newQ {
            parts.append("\(oldQ) → \(newQ)")
        }

        if let oldScore = item.existingCustomFormatScore, oldScore != item.customFormatScore {
            parts.append("score \(oldScore)→\(item.customFormatScore)")
        }

        let oldFormats = Set(item.existingCustomFormats)
        let newFormats = Set(item.customFormats)
        let gained = newFormats.subtracting(oldFormats).sorted()
        let lost = oldFormats.subtracting(newFormats).sorted()
        var formatBits = gained.map { "+\($0)" }
        formatBits += lost.map { "-\($0)" }
        if !formatBits.isEmpty {
            parts.append(formatBits.joined(separator: " "))
        }

        if let oldSize = item.existingSize, oldSize > 0 {
            let oldStr = ByteCountFormatter.string(fromByteCount: oldSize, countStyle: .file)
            let newStr = ByteCountFormatter.string(fromByteCount: item.sizeTotal, countStyle: .file)
            parts.append("\(oldStr)→\(newStr)")
        }

        guard !parts.isEmpty else { return nil }
        return "UPGRADE: " + parts.joined(separator: " · ")
    }

}
