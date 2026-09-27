import Foundation
import MediaKit

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

    /// Resolves the model's own taste picks through the arr lookup so the chat shows actionable cards;
    /// `tmdb_discover_*` is algorithmic and poor at taste-based queries.
    func suggestTitles(_ args: JSONValue) async throws -> ToolCallOutput {
        let kind = Self.stringArg(args, key: "kind").lowercased()
        guard kind == "series" || kind == "movie" else {
            return ToolCallOutput(text: "suggest_titles requires kind='series' or kind='movie'.")
        }
        let items = Self.suggestItems(args)
        guard !items.isEmpty else {
            return ToolCallOutput(text: "suggest_titles needs a non-empty 'items' array of {title, year?} picks.")
        }
        // A deep library owns most canonical picks, so resolving 40 at once beats another round.
        let capped = Array(items.prefix(40))
        // Ownership is a fact, not a judgement, so it is safe to drop here — unlike genre or mood.
        let excludeOwned = Self.optionalBoolArg(args, key: "exclude_owned") ?? false

        let source: QueueItem.Source = (kind == "series") ? .sonarr : .radarr
        let config = (kind == "series") ? sonarr : radarr
        guard config.isConfigured else {
            return ToolCallOutput(text: "\(source.displayName) is not configured — can't resolve \(kind) suggestions.")
        }
        let client = SearchClient(config: config, source: source)

        // Owned cards need `inLibraryArrId` so a tap opens DetailView instead of SearchAddPanel.
        async let libraryMapFetch: [Int: LibraryOwnership] = (kind == "series")
            ? sonarrLibraryByTVDBId()
            : radarrLibraryByTMDBId()

        // Collected by index: the model's ordering is relevance signal.
        var resolved: [(index: Int, result: SearchResult)] = []
        var missing: [(index: Int, label: String)] = []

        await withTaskGroup(of: (Int, Result<SearchResult?, Error>).self) { group in
            for (idx, item) in capped.enumerated() {
                group.addTask { [client] in
                    do {
                        let query = Self.lookupTerm(title: item.title, year: item.year, tmdbId: item.tmdbId)
                        let hits = try await Self.searchWithYearAwareness(client: client, query: query)
                        // An id ref is exact; a titled pick must BE one of the
                        // hits, or it is reported missing rather than swapped.
                        let match = item.tmdbId != nil ? hits.first : PickMatcher.bestIndex(
                            title: item.title, year: item.year,
                            in: hits.map { PickMatcher.Candidate(titles: [$0.title], year: $0.year, votes: $0.votes) }
                        ).map { hits[$0] }
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
        // `.id` is tvdbId for series / tmdbId for movies, the library map's keys.
        let tagged = resolved.map { entry -> SearchResult in
            guard let ownership = libraryMap[entry.result.externalId] else { return entry.result }
            return entry.result.withLibraryOwnership(ownership)
        }
        let afterOwned = excludeOwned ? tagged.filter { $0.inLibraryArrId == nil } : tagged
        let droppedAsOwned = tagged.count - afterOwned.count

        // Cross-call memory: in a big library every retry otherwise resurfaces the same lone unowned pick.
        let results = afterOwned.filter { !surfacedSuggestionIds.contains($0.id) }
        let repeatCount = afterOwned.count - results.count
        for r in results { surfacedSuggestionIds.insert(r.id) }

        if results.isEmpty {
            if repeatCount > 0 {
                return ToolCallOutput(text: "Every surviving pick in this call was ALREADY surfaced as a card earlier in this conversation (\(repeatCount) repeat\(repeatCount == 1 ? "" : "s"))\(droppedAsOwned > 0 ? ", and \(droppedAsOwned) more are in the library" : ""). STOP calling suggest_titles for this ask — the user can see those cards. Summarize what is on screen or ask them a question instead.")
            }
            if droppedAsOwned > 0 {
                return ToolCallOutput(text: "All \(droppedAsOwned) resolved picks are already in the user's library. Do NOT immediately guess another batch — the canon is owned. Go for genuinely deeper cuts in ONE more call at most, or first run check_titles on a 25-40 candidate list and suggest only what it reports as missing.")
            }
            return ToolCallOutput(text: "None of those picks resolved through \(source.displayName) lookup. Do NOT retry the same titles with rephrasings; check spelling/years or pick different titles.")
        }

        var text = Self.formatSuggestionsCondensed(
            resolved: results,
            missing: missing.map { $0.label },
            kind: kind
        )
        if droppedAsOwned > 0 {
            text += "\n\(droppedAsOwned) pick\(droppedAsOwned == 1 ? " was" : "s were") dropped as already in the library."
        }
        if repeatCount > 0 {
            text += "\n\(repeatCount) repeat\(repeatCount == 1 ? "" : "s") of cards already shown earlier were dropped."
        }
        text += "\nPresent these to the user now. Do NOT call suggest_titles again for the same ask — if they want more, they will say so."
        let rich: ChatRichContent = (kind == "series") ? .searchSeriesResults(results) : .searchMovieResults(results)
        return ToolCallOutput(text: text, rich: rich)
    }

    /// Messages are inlined only when there is something to report, to keep a green result compact.
    func healthCheck() async throws -> ToolCallOutput {
        let configured: [(QueueItem.Source, ServiceConfig)] = [
            (.sonarr, sonarr), (.radarr, radarr),
            (.lidarr, lidarr), (.whisparr, whisparr),
        ].filter { $0.1.isConfigured }

        let clientLines = await downloadClientHealthLines()

        guard !configured.isEmpty else {
            if clientLines.isEmpty {
                return ToolCallOutput(text: "No services are configured.")
            }
            return ToolCallOutput(text: (["Download clients:"] + clientLines).joined(separator: "\n"))
        }

        var report: [(source: QueueItem.Source, records: [ArrHealth], error: String?)] = []
        await withTaskGroup(of: (QueueItem.Source, Result<[ArrHealth], Error>).self) { group in
            for (source, cfg) in configured {
                group.addTask { [cfg] in
                    do {
                        let records: [ArrHealth]
                        records = try await ServiceHandles.arr(source, config: cfg).fetchHealth()
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

    nonisolated private static func probeDownloadClient(_ kind: DownloadClientKind, _ cfg: ServiceConfig) async throws -> String {
        switch kind {
        case .qbittorrent:  return try await QbittorrentClient(config: cfg).testConnection()
        case .transmission: return try await TransmissionClient(config: cfg).testConnection()
        case .nzbget:       return try await NzbgetClient(config: cfg).testConnection()
        case .sabnzbd:      return try await SabnzbdClient(config: cfg).testConnection()
        case .rtorrent:     return try await RtorrentClient(config: cfg).testConnection()
        case .deluge:       return try await DelugeClient(config: cfg).testConnection()
        }
    }

    // MARK: - Lifecycle control tools (monitor + search)

    /// Enabling always fires a SeasonSearch: with an opt-out the model defaulted it off and still
    /// claimed "search queued". The result reports each step's real outcome.
    func sonarrMonitorSeason(_ args: JSONValue) async throws -> ToolCallOutput {
        let seriesId = Self.intArg(args, key: "seriesId")
        // Chat requests often name several seasons; SeasonSearch is per-season, so one call each.
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
        let client = sonarrClient

        func list(_ xs: [Int]) -> String { xs.map(String.init).joined(separator: ", ") }

        // A single rejected season doesn't sink the rest.
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

        // Report the per-season outcome so the model can't paper over a partial failure.
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

    func sonarrSearchEpisodesTool(_ args: JSONValue) async throws -> ToolCallOutput {
        let ids = Self.intArrayArg(args, key: "episodeIds")
        guard !ids.isEmpty else {
            return ToolCallOutput(text: "Need episodeIds (non-empty integer array).")
        }
        guard sonarr.isConfigured else {
            return ToolCallOutput(text: "Sonarr is not configured.")
        }
        do {
            try await sonarrClient.searchEpisodes(episodeIds: ids)
            return ToolCallOutput(text: "Queued search for \(ids.count) episode\(ids.count == 1 ? "" : "s").")
        } catch {
            return ToolCallOutput(text: "Couldn't queue search: \(error.localizedDescription)")
        }
    }

    /// Radarr's monitored flag isn't changed.
    func radarrSearchMovieTool(_ args: JSONValue) async throws -> ToolCallOutput {
        let movieId = Self.intArg(args, key: "movieId")
        guard movieId > 0 else {
            return ToolCallOutput(text: "Need a valid movieId — run radarr_get_movies to resolve it.")
        }
        guard radarr.isConfigured else {
            return ToolCallOutput(text: "Radarr is not configured.")
        }
        // Radarr answers 200 to a MoviesSearch for an unknown id, so validate first. A tmdbId in the
        // movieId slot that maps to an owned movie is corrected silently.
        let movies = await LibraryIndex.shared.movies(config: radarr)
        let resolvedId: Int
        let title: String
        if let hit = movies.first(where: { $0.id == movieId }) {
            resolvedId = movieId
            title = hit.title
        } else if let byTmdb = movies.first(where: { $0.tmdbId == movieId }), let realId = byTmdb.id {
            resolvedId = realId
            title = byTmdb.title
        } else {
            return ToolCallOutput(text: "movieId \(movieId) is NOT in the Radarr library, so there is nothing to search for. This tool only re-runs the indexer search for movies the user ALREADY has. There is NO tool that adds a movie — adding happens when the USER taps a card from radarr_search and confirms in the add panel. If they asked to add this title, tell them to tap its card.")
        }
        do {
            try await radarrClient.searchMovie(movieId: resolvedId)
            return ToolCallOutput(text: "Search queued for \(title) (movieId \(resolvedId)). Indexers will report back into the regular queue.")
        } catch {
            return ToolCallOutput(text: "Couldn't queue search: \(error.localizedDescription)")
        }
    }

    /// Capped to 40 albums; a trailing note tells the model how many were dropped.
    func lidarrGetArtistAlbums(_ args: JSONValue) async throws -> ToolCallOutput {
        let artistId = Self.intArg(args, key: "artistId")
        guard artistId > 0 else {
            return ToolCallOutput(text: "Need a valid artistId — run lidarr_get_artists to resolve it.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let typeFilter = Self.stringArg(args, key: "albumType").lowercased()
        let albums: [ArrAlbum]
        do {
            albums = try await lidarrClient.fetchArtistAlbums(artistId: artistId)
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
            return "• albumId=\(rec.id.map(String.init) ?? "?") · \(rec.title)\(yearPart)\(typePart) · \(mon) \(have)/\(total) tracks"
        }
        // Name the artist: an id-only header gives the model no way to notice a wrong id.
        let name = await artistName(id: artistId)
        let who = name.map { "\($0) (artistId=\(artistId))" } ?? "artistId=\(artistId)"
        var out = "\(who) has \(filtered.count) album\(filtered.count == 1 ? "" : "s")"
        if !typeFilter.isEmpty { out += " (type=\(typeFilter))" }
        out += ":\n" + lines.joined(separator: "\n")
        if filtered.count > cap {
            out += "\n(\(filtered.count - cap) more not shown — narrow with albumType to see them all.)"
        }
        // Covers come from Lidarr, so the shown slice is what the rail renders — no second fetch.
        let cards = shown.compactMap { rec in
            rec.id.map { id in ChatAlbum(
                id: id,
                title: rec.title,
                year: Self.yearFromReleaseDate(rec.releaseDate),
                monitored: rec.monitored ?? false,
                trackFileCount: rec.statistics?.trackFileCount ?? 0,
                trackCount: rec.statistics?.totalTrackCount ?? rec.statistics?.trackCount ?? 0,
                images: rec.images ?? []
            ) }
        }
        return ToolCallOutput(text: out, rich: .albums(artist: name, albums: Array(cards)))
    }

    private func artistName(id: Int) async -> String? {
        guard let artists = try? await lidarrClient.fetchAllArtists() else { return nil }
        return artists.first { $0.id == id }?.artistName
    }

    nonisolated static func yearFromReleaseDate(_ raw: String?) -> Int? {
        guard let raw, raw.count >= 4 else { return nil }
        return Int(raw.prefix(4))
    }

    /// Like `sonarrMonitorSeason`, state=true always fires the search.
    func lidarrMonitorAlbum(_ args: JSONValue) async throws -> ToolCallOutput {
        let albumId = Self.intArg(args, key: "albumId")
        guard albumId > 0 else {
            return ToolCallOutput(text: "Need a valid albumId — run lidarr_get_artist_albums to resolve it.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let state = Self.optionalBoolArg(args, key: "state") ?? true
        let client = lidarrClient
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

    func lidarrSearchAlbumTool(_ args: JSONValue) async throws -> ToolCallOutput {
        let albumId = Self.intArg(args, key: "albumId")
        guard albumId > 0 else {
            return ToolCallOutput(text: "Need a valid albumId.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        do {
            try await lidarrClient.searchAlbum(albumId: albumId)
            return ToolCallOutput(text: "Search queued for album \(albumId).")
        } catch {
            return ToolCallOutput(text: "Couldn't queue search: \(error.localizedDescription)")
        }
    }

    /// Drops malformed entries so one fumbled item doesn't kill the call. No `reason` field:
    /// model-written reasons became plot blurbs and slowed generation.
    nonisolated static func suggestItems(_ value: JSONValue) -> [(title: String, year: Int?, tmdbId: Int?)] {
        guard case .object(let dict) = value, case .array(let arr) = dict["items"] else { return [] }
        func intValue(_ raw: JSONValue?) -> Int? {
            switch raw {
            case .number(let n): return Int(n)
            case .string(let s): return Int(s)
            default: return nil
            }
        }
        return arr.compactMap { entry -> (String, Int?, Int?)? in
            guard case .object(let obj) = entry,
                  case .string(let title) = obj["title"],
                  !title.isEmpty else { return nil }
            return (title, intValue(obj["year"]), intValue(obj["tmdbId"]))
        }
    }

    /// An exact `tmdb:` ref when the model supplied the id (no wrong-remake risk), else title plus year.
    nonisolated static func lookupTerm(title: String, year: Int?, tmdbId: Int?) -> String {
        if let tmdbId { return "tmdb:\(tmdbId)" }
        return year.map { "\(title) \($0)" } ?? title
    }

    /// Kept under ~300 tokens for 15 items to spare the local LLM's context window.
    nonisolated static func formatSuggestionsCondensed(
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
                // The media server only knows owned titles, so an unowned pick never carries a marker.
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

    /// Surfaces year-matching hits first: TMDB's popularity ranking buries upcoming or niche entries.
    nonisolated static func searchWithYearAwareness(client: SearchClient, query: String) async throws -> [SearchResult] {
        let primary = try await client.lookup(query: query)
        guard let year = extractYear(from: query) else { return primary }
        let matched = primary.filter { $0.year == year }
        let rest = primary.filter { $0.year != year }
        if !matched.isEmpty {
            return matched + rest
        }
        // Re-query without the year so the lookup has a cleaner term, then filter by year.
        let bareQuery = query
            .replacingOccurrences(of: String(year), with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()[]-,"))
        guard bareQuery != query, !bareQuery.isEmpty else { return primary }
        let secondary = try await client.lookup(query: bareQuery)
        let secondaryYear = secondary.filter { $0.year == year }
        // Keyed on row identity, not the foreign key: TMDB-sourced series have no foreign key yet.
        var seen = Set<String>()
        var merged: [SearchResult] = []
        for r in secondaryYear + primary + secondary where seen.insert(r.id).inserted {
            merged.append(r)
        }
        return merged
    }

    nonisolated static func extractYear(from query: String) -> Int? {
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

    nonisolated static func seasonsSummary(for rec: ArrSeries, filter: Int?) -> String {
        let seasons = rec.seasons?.filter { $0.seasonNumber > 0 } ?? []
        guard !seasons.isEmpty else { return "" }
        if let target = filter {
            guard let s = seasons.first(where: { $0.seasonNumber == target }) else {
                return " · S\(target): not found in record"
            }
            return " · " + Self.formatSeasonLine(s)
        }
        let shown = seasons.prefix(12).map(Self.formatSeasonLine).joined(separator: ", ")
        let trailing = seasons.count > 12 ? ", …" : ""
        return " · seasons: \(shown)\(trailing)"
    }

    nonisolated static func formatSeasonLine(_ s: ArrSeason) -> String {
        let mon = (s.monitored ?? false) ? "✓" : "✗"
        let have = s.statistics?.episodeFileCount ?? 0
        let total = s.statistics?.totalEpisodeCount ?? s.statistics?.episodeCount ?? 0
        return "S\(s.seasonNumber) \(mon) \(have)/\(total)"
    }

    func getCalendar(_ args: JSONValue) async throws -> ToolCallOutput {
        let requested = Self.stringArg(args, key: "service").lowercased()

        // Whisparr only when the AI-access toggle is on, like every other whisparr tool.
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

        let (items, failed) = await UpcomingService.calendars(targets)
        let merged = items.sorted { $0.airDate < $1.airDate }
        let failures = failed.map { "\($0.0.displayName) calendar unreachable — \($0.1.localizedDescription)" }

        var text = Self.formatCalendarCondensed(merged)
        if !failures.isEmpty {
            text += "\n" + failures.map { "⚠️ \($0)" }.joined(separator: "\n")
        }
        return ToolCallOutput(text: text, rich: .calendar(merged))
    }

    // MARK: - Lidarr tool implementations

    func searchArtist(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearchArtist(args: args)
    }

    func listArtists(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runLibraryList(
            args: args, source: .lidarr, config: lidarr,
            itemNounSingular: "artist", itemNounPlural: "artists",
            fetch: { try await self.lidarrClient.fetchAllArtists() },
            filterMatch: { rec, q in (rec.artistName ?? "").lowercased().contains(q) },
            line: { r in
                let name = r.artistName ?? "(untitled)"
                // artistId first: `lidarr_get_artist_albums` requires it and only this tool supplies it;
                // without it the model guessed ids.
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
            fetch: { try await self.whisparrClient.fetchAllMovies() },
            filterMatch: { rec, q in rec.title.lowercased().contains(q) },
            line: { r in
                let title = r.title
                let yearPart = r.year.map { " (\($0))" } ?? ""
                let fileMark = (r.hasFile ?? false) ? " · downloaded" : " · missing"
                return "• \(title)\(yearPart)\(fileMark)"
            },
            rich: { .libraryScenes($0) }
        )
    }

    nonisolated static func formatCalendarCondensed(_ items: [UpcomingItem]) -> String {
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

    /// Queue items carry both incoming and existing-file metadata, so upgrades are explained in one call.
    /// Whisparr rides the `aiKnowsAboutWhisparr` gate: an arr hidden from the model must not leak in here.
    func listDownloadQueue(_ args: JSONValue) async throws -> ToolCallOutput {
        let configured: [(QueueItem.Source, ServiceConfig)] = [
            (.sonarr, sonarr), (.radarr, radarr), (.lidarr, lidarr),
            (.whisparr, aiKnowsAboutWhisparr ? whisparr : .empty),
        ].filter { $0.1.isConfigured }

        guard !configured.isEmpty else {
            return ToolCallOutput(text: "No arr is configured.")
        }

        var items: [QueueItem] = []
        var failures: [String] = []
        await withTaskGroup(of: (QueueItem.Source, Result<[QueueItem], Error>).self) { group in
            for (source, cfg) in configured {
                group.addTask { [cfg] in
                    do {
                        let queue: [QueueItem]
                        queue = try await ServiceHandles.arr(source, config: cfg).fetchQueue()
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
        items.sort { lhs, rhs in
            if lhs.isUpgrade != rhs.isUpgrade { return lhs.isUpgrade }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let text = Self.formatQueueCondensed(items, failures: failures)
        return ToolCallOutput(text: text, rich: .downloadQueue(items))
    }

    nonisolated static func formatQueueCondensed(_ items: [QueueItem], failures: [String] = []) -> String {
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

    /// `UPGRADE: 1080p → 2160p · score 50→120 · +DV -X · 8.1GB→24.3GB`; nil when nothing differs.
    nonisolated static func upgradeDiffFragment(_ item: QueueItem) -> String? {
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
