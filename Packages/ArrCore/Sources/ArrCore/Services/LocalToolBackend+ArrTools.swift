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
        // Hard cap so the tool stays responsive even if the model goes
        // overboard ("here's 50 picks"). 15 is plenty for a single round
        // of suggestions and matches the *_search top-N convention.
        let capped = Array(items.prefix(15))

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
                        let query = item.year.map { "\(item.title) \($0)" } ?? item.title
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
        let results = resolved.map { entry -> SearchResult in
            guard let arrId = libraryMap[entry.result.id] else { return entry.result }
            return entry.result.withInLibraryArrId(arrId)
        }
        let text = Self.formatSuggestionsCondensed(
            resolved: results,
            missing: missing.map { $0.label },
            kind: kind
        )
        let rich: ChatRichContent = (kind == "series") ? .searchSeriesResults(results) : .searchMovieResults(results)
        return ToolCallOutput(text: text, rich: rich)
    }

    /// Aggregated health check across every configured arr. Each arr's
    /// `/health` endpoint returns the warnings + errors its own UI shows in
    /// the bell icon — disconnected indexers, missing root folders, full
    /// disk, etc. The model gets a per-arr one-line summary; full-detail
    /// messages are inlined only when there's something to report so the
    /// output stays compact when everything's green.
    func arrHealth() async throws -> ToolCallOutput {
        let configured: [(QueueItem.Source, ServiceConfig)] = [
            (.sonarr, sonarr), (.radarr, radarr),
            (.lidarr, lidarr), (.whisparr, whisparr),
        ].filter { $0.1.isConfigured }

        guard !configured.isEmpty else {
            return ToolCallOutput(text: "No arr services are configured.")
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
        return ToolCallOutput(text: lines.joined(separator: "\n"))
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
        guard let seasonNumber = Self.optionalIntArg(args, key: "seasonNumber") else {
            return ToolCallOutput(text: "Need seasonNumber (integer).")
        }
        let state = Self.optionalBoolArg(args, key: "state") ?? true
        guard seriesId > 0 else {
            return ToolCallOutput(text: "Need a valid seriesId — run sonarr_get_series to resolve it.")
        }
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        let client = SonarrClient(config: sonarr)
        do {
            try await client.setSeasonMonitored(seriesId: seriesId, seasonNumber: seasonNumber, monitored: state)
        } catch {
            return ToolCallOutput(text: "FAILED to update monitoring: \(error.localizedDescription)")
        }
        guard state else {
            return ToolCallOutput(text: "OK: stopped monitoring season \(seasonNumber) of seriesId=\(seriesId). No search triggered.")
        }
        // Monitor flipped on → kick the search. Report the outcome
        // explicitly so the model can't paper over a failure.
        do {
            try await client.searchSeason(seriesId: seriesId, seasonNumber: seasonNumber)
            return ToolCallOutput(text: "OK: season \(seasonNumber) of seriesId=\(seriesId) is now monitored, and SeasonSearch command was POST'd to Sonarr. Indexer results will land in the queue when releases match — typically within ~30 seconds, longer if indexers are slow.")
        } catch {
            return ToolCallOutput(text: "PARTIAL: monitoring on, but Sonarr rejected the search command (\(error.localizedDescription)). Tell the user the season is monitored but they should retry shortly or use the season's search button in DetailView. DO NOT call sonarr_search_episodes as a workaround — it grabs per-episode releases instead of a season pack.")
        }
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
        var out = "Artist \(artistId) has \(filtered.count) album\(filtered.count == 1 ? "" : "s")"
        if !typeFilter.isEmpty { out += " (type=\(typeFilter))" }
        out += ":\n" + lines.joined(separator: "\n")
        if filtered.count > cap {
            out += "\n(\(filtered.count - cap) more not shown — narrow with albumType to see them all.)"
        }
        return ToolCallOutput(text: out)
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

    /// Pull `items: [{title, year?}]` out of the JSON-RPC arguments.
    /// Permissive — drops malformed entries silently so a model that
    /// fumbles one item doesn't kill the whole call.
    static func suggestItems(_ value: JSONValue) -> [(title: String, year: Int?)] {
        guard case .object(let dict) = value, case .array(let arr) = dict["items"] else { return [] }
        return arr.compactMap { entry -> (String, Int?)? in
            guard case .object(let obj) = entry,
                  case .string(let title) = obj["title"],
                  !title.isEmpty else { return nil }
            let year: Int? = {
                guard let raw = obj["year"] else { return nil }
                switch raw {
                case .number(let n): return Int(n)
                case .string(let s): return Int(s)
                default: return nil
                }
            }()
            return (title, year)
        }
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
                let state = (r.inLibraryArrId != nil) ? " [in library]" : ""
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
        var seen = Set<Int>()
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

    /// `sonarr_get_series` lists library series, optionally filtered by
    /// title query, and (optionally) zooms into a specific season's
    /// monitor + missing state. Adding the `seasonNumber` filter lets
    /// the LLM answer "do I have S3 of X monitored?" in one round-trip
    /// without paying for the per-series detail tool.
    func listSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        let seasonFilter = Self.optionalIntArg(args, key: "seasonNumber")
        return try await runLibraryList(
            args: args, source: .sonarr, config: sonarr,
            itemNounSingular: "series", itemNounPlural: "series",
            fetch: { try await SonarrClient(config: self.sonarr).fetchAllSeries() },
            filterMatch: { rec, q in (rec.title ?? "").lowercased().contains(q) },
            line: { r in
                let title = r.title ?? "(untitled)"
                let yearPart = r.year.map { " (\($0))" } ?? ""
                let idParts: [String] = [
                    r.id.map { "seriesId=\($0)" },
                    r.tvdbId.map { "tvdbId=\($0)" },
                ].compactMap { $0 }
                let idPart = idParts.isEmpty ? "" : " · " + idParts.joined(separator: ", ")
                let statusPart = r.status.map { " · \($0)" } ?? ""
                let seasonsPart = Self.seasonsSummary(for: r, filter: seasonFilter)
                return "• \(title)\(yearPart)\(idPart)\(statusPart)\(seasonsPart)"
            },
            rich: { .librarySeries($0) }
        )
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

    func listMovies(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runLibraryList(
            args: args, source: .radarr, config: radarr,
            itemNounSingular: "movie", itemNounPlural: "movies",
            fetch: { try await RadarrClient(config: self.radarr).fetchAllMovies() },
            filterMatch: { rec, q in (rec.title ?? "").lowercased().contains(q) },
            line: { r in
                let title = r.title ?? "(untitled)"
                let yearPart = r.year.map { " (\($0))" } ?? ""
                let idPart = r.tmdbId.map { " · tmdbId=\($0)" } ?? ""
                let fileMark = (r.hasFile ?? false) ? " · downloaded" : " · missing"
                return "• \(title)\(yearPart)\(idPart)\(fileMark)"
            },
            rich: { .libraryMovies($0) }
        )
    }

    func sonarrCalendar() async throws -> ToolCallOutput {
        try await runCalendar(source: .sonarr, config: sonarr) {
            try await SonarrClient(config: self.sonarr).fetchCalendar()
        }
    }

    func radarrCalendar() async throws -> ToolCallOutput {
        try await runCalendar(source: .radarr, config: radarr) {
            try await RadarrClient(config: self.radarr).fetchCalendar()
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
                let idPart = r.foreignArtistId.map { " · foreignArtistId=\($0)" } ?? ""
                let albumCount = r.statistics?.albumCount.map { " · \($0) album\($0 == 1 ? "" : "s")" } ?? ""
                return "• \(name)\(idPart)\(albumCount)"
            },
            rich: { .libraryArtists($0) }
        )
    }

    func lidarrCalendar() async throws -> ToolCallOutput {
        try await runCalendar(source: .lidarr, config: lidarr) {
            try await LidarrClient(config: self.lidarr).fetchCalendar()
        }
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

    func whisparrCalendar() async throws -> ToolCallOutput {
        try await runCalendar(source: .whisparr, config: whisparr) {
            try await WhisparrClient(config: self.whisparr).fetchCalendar()
        }
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

}
