import Foundation

/// In-process tool backend. Uses ArrCore's existing Sonarr/Radarr clients.
/// Exposes the same 6 tools as mcp-arr, but with zero external dependencies.
public actor LocalToolBackend: ToolBackend {
    private let sonarr: ServiceConfig
    private let radarr: ServiceConfig
    private let lidarr: ServiceConfig
    private let whisparr: ServiceConfig
    private let aiKnowsAboutWhisparr: Bool
    private let tmdbApiKey: String

    public init(sonarr: ServiceConfig, radarr: ServiceConfig, lidarr: ServiceConfig = .empty,
                whisparr: ServiceConfig = .empty, aiKnowsAboutWhisparr: Bool = false,
                tmdbApiKey: String = "") {
        self.sonarr = sonarr
        self.radarr = radarr
        self.lidarr = lidarr
        self.whisparr = whisparr
        self.aiKnowsAboutWhisparr = aiKnowsAboutWhisparr
        self.tmdbApiKey = tmdbApiKey
    }

    private var tmdbEnabled: Bool { !tmdbApiKey.isEmpty }

    public func listTools() async throws -> [MCPTool] {
        ChatToolCatalog.tools(
            includeSonarr: sonarr.isConfigured,
            includeRadarr: radarr.isConfigured,
            includeLidarr: lidarr.isConfigured,
            includeWhisparr: whisparr.isConfigured && aiKnowsAboutWhisparr,
            includeTMDBMovies: tmdbEnabled && radarr.isConfigured,
            includeTMDBSeries: tmdbEnabled && sonarr.isConfigured
        )
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolCallOutput {
        // Guard Whisparr tools when the toggle is off
        if name.hasPrefix("whisparr_") && !aiKnowsAboutWhisparr {
            return ToolCallOutput(text: "Whisparr AI access is disabled in Settings.")
        }
        // Guard TMDB tools when no key is configured
        if name.hasPrefix("tmdb_") && !tmdbEnabled {
            return ToolCallOutput(text: "TMDB API key is not configured in Settings → AI → Discovery.")
        }
        switch name {
        case "sonarr_search":       return try await searchSeries(arguments)
        case "radarr_search":       return try await searchMovie(arguments)
        case "sonarr_get_series":   return try await listSeries(arguments)
        case "radarr_get_movies":   return try await listMovies(arguments)
        case "sonarr_get_calendar": return try await sonarrCalendar()
        case "radarr_get_calendar": return try await radarrCalendar()
        // `*_add_*` tools used to live here. Removed in favour of "model
        // surfaces, user adds via the SearchAddPanel card flow" — see
        // ChatToolCatalog for the rationale. The model now drops the user
        // off at a tappable card; tapping opens the same panel `+` uses,
        // with profile/folder/quality pickers and a single confirm button.
        case "lidarr_search":       return try await searchArtist(arguments)
        case "lidarr_get_artists":  return try await listArtists(arguments)
        case "lidarr_get_calendar": return try await lidarrCalendar()
        case "whisparr_search":     return try await searchScene(arguments)
        case "whisparr_get_movies": return try await listScenes(arguments)
        case "whisparr_get_calendar": return try await whisparrCalendar()
        case "tmdb_search_person":          return try await tmdbSearchPerson(arguments)
        case "tmdb_person_movie_credits":   return try await tmdbPersonMovieCredits(arguments)
        case "tmdb_person_tv_credits":      return try await tmdbPersonTVCredits(arguments)
        case "tmdb_discover_movies":        return try await tmdbDiscoverMovies(arguments)
        case "tmdb_discover_series":        return try await tmdbDiscoverSeries(arguments)
        case "suggest_titles":              return try await suggestTitles(arguments)
        case "arr_health":                  return try await arrHealth()
        default:
            throw LocalToolError.unknownTool(name)
        }
    }

    // MARK: - Generic helpers — collapse the per-arr handler boilerplate

    /// Standard `*_search` shape: required `query` arg, configured check,
    /// SearchClient lookup, condensed text + rich payload. Series/movie/scene
    /// share this shape; lidarr_search uses its own helper because the
    /// formatter and rich case both diverge (artist subtitle, foreignArtistId
    /// label) — see `runSearchArtist`.
    private func runSearch(
        args: JSONValue,
        source: QueueItem.Source,
        config: ServiceConfig,
        kind: String,
        yearAware: Bool,
        rich: ([SearchResult]) -> ChatRichContent
    ) async throws -> ToolCallOutput {
        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else {
            return ToolCallOutput(text: "Please provide a search query.")
        }
        guard config.isConfigured else {
            return ToolCallOutput(text: "\(source.displayName) is not configured.")
        }
        let client = SearchClient(config: config, source: source)
        let results = yearAware
            ? try await Self.searchWithYearAwareness(client: client, query: query)
            : try await client.lookup(query: query)
        let text = Self.formatSearchResultsCondensed(results, query: query, kind: kind)
        return ToolCallOutput(text: text, rich: rich(results))
    }

    private func runSearchArtist(args: JSONValue) async throws -> ToolCallOutput {
        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else {
            return ToolCallOutput(text: "Please provide a search query.")
        }
        guard lidarr.isConfigured else {
            return ToolCallOutput(text: "Lidarr is not configured.")
        }
        let client = SearchClient(config: lidarr, source: .lidarr)
        let results = try await client.lookup(query: query)
        let text = Self.formatArtistSearchCondensed(results, query: query)
        return ToolCallOutput(text: text, rich: .searchArtistResults(results))
    }

    /// Standard `*_get_*` shape: configured check, fetch full library,
    /// optional substring filter on a record-specific field, condensed text,
    /// rich payload. The closure approach keeps it type-safe across the four
    /// different record types without resorting to a protocol.
    private func runLibraryList<Rec>(
        args: JSONValue,
        source: QueueItem.Source,
        config: ServiceConfig,
        itemNounSingular: String,
        itemNounPlural: String,
        fetch: () async throws -> [Rec],
        filterMatch: (Rec, String) -> Bool,
        line: (Rec) -> String,
        rich: ([Rec]) -> ChatRichContent
    ) async throws -> ToolCallOutput {
        guard config.isConfigured else {
            return ToolCallOutput(text: "\(source.displayName) is not configured.")
        }
        let filter = Self.stringArg(args, key: "query").lowercased()
        let all = try await fetch()
        let matched = filter.isEmpty ? all : all.filter { filterMatch($0, filter) }
        let text = Self.formatLibrary(
            serviceName: source.displayName,
            itemNounSingular: itemNounSingular,
            itemNounPlural: itemNounPlural,
            items: matched, filter: filter, line: line
        )
        return ToolCallOutput(text: text, rich: rich(matched))
    }

    /// Standard `*_get_calendar` shape: configured check, fetch, format.
    /// All four calendar handlers reduce to a one-line call to this.
    private func runCalendar(
        source: QueueItem.Source,
        config: ServiceConfig,
        fetch: () async throws -> [UpcomingItem]
    ) async throws -> ToolCallOutput {
        guard config.isConfigured else {
            return ToolCallOutput(text: "\(source.displayName) is not configured.")
        }
        let items = try await fetch()
        let text = Self.formatCalendarCondensed(items)
        return ToolCallOutput(text: text, rich: .calendar(items))
    }

    // MARK: - Tool implementations

    private func searchSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearch(args: args, source: .sonarr, config: sonarr, kind: "series",
                            yearAware: true, rich: { .searchSeriesResults($0) })
    }

    private func searchMovie(_ args: JSONValue) async throws -> ToolCallOutput {
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
    private func suggestTitles(_ args: JSONValue) async throws -> ToolCallOutput {
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

        let results = resolved.map { $0.result }
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
    private func arrHealth() async throws -> ToolCallOutput {
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

    /// Pull `items: [{title, year?}]` out of the JSON-RPC arguments.
    /// Permissive — drops malformed entries silently so a model that
    /// fumbles one item doesn't kill the whole call.
    private static func suggestItems(_ value: JSONValue) -> [(title: String, year: Int?)] {
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
    private static func formatSuggestionsCondensed(
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
    private static func searchWithYearAwareness(client: SearchClient, query: String) async throws -> [SearchResult] {
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

    private static func extractYear(from query: String) -> Int? {
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

    private func listSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runLibraryList(
            args: args, source: .sonarr, config: sonarr,
            itemNounSingular: "series", itemNounPlural: "series",
            fetch: { try await SonarrClient(config: self.sonarr).fetchAllSeries() },
            filterMatch: { rec, q in (rec.title ?? "").lowercased().contains(q) },
            line: { r in
                let title = r.title ?? "(untitled)"
                let yearPart = r.year.map { " (\($0))" } ?? ""
                let idPart = r.tvdbId.map { " · tvdbId=\($0)" } ?? ""
                let statusPart = r.status.map { " · \($0)" } ?? ""
                return "• \(title)\(yearPart)\(idPart)\(statusPart)"
            },
            rich: { .librarySeries($0) }
        )
    }

    private func listMovies(_ args: JSONValue) async throws -> ToolCallOutput {
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

    private func sonarrCalendar() async throws -> ToolCallOutput {
        try await runCalendar(source: .sonarr, config: sonarr) {
            try await SonarrClient(config: self.sonarr).fetchCalendar()
        }
    }

    private func radarrCalendar() async throws -> ToolCallOutput {
        try await runCalendar(source: .radarr, config: radarr) {
            try await RadarrClient(config: self.radarr).fetchCalendar()
        }
    }

    // MARK: - Lidarr tool implementations

    private func searchArtist(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearchArtist(args: args)
    }

    private func listArtists(_ args: JSONValue) async throws -> ToolCallOutput {
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

    private func lidarrCalendar() async throws -> ToolCallOutput {
        try await runCalendar(source: .lidarr, config: lidarr) {
            try await LidarrClient(config: self.lidarr).fetchCalendar()
        }
    }

    // MARK: - Formatting helpers

    private static func stringArg(_ value: JSONValue, key: String) -> String {
        if case .object(let dict) = value, case .string(let s) = dict[key] {
            return s
        }
        return ""
    }

    /// Extract an integer arg. Tolerates JSON numbers OR strings (LLM might
    /// serialize "12345" instead of 12345).
    private static func intArg(_ value: JSONValue, key: String) -> Int {
        guard case .object(let dict) = value, let v = dict[key] else { return 0 }
        switch v {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s) ?? 0
        default: return 0
        }
    }

    /// Condensed search result text for the LLM — id + title + year only.
    /// No overview, no rating, no year-match markers (the carousel makes those visible).
    private static func formatSearchResultsCondensed(
        _ results: [SearchResult],
        query: String,
        kind: String
    ) -> String {
        guard !results.isEmpty else { return "No results found." }
        let top = results.prefix(15)
        let lines = top.map { r -> String in
            let yearPart = r.year.map { " (\($0))" } ?? ""
            return "• \(r.title)\(yearPart)"
        }
        // No more "pass tvdbId to sonarr_add_series" instruction — add tools
        // are gone. Cards in `rich` are tappable; the user opens
        // SearchAddPanel from the chat to confirm/configure/add.
        var out = "Surfaced \(results.count) \(kind) result\(results.count == 1 ? "" : "s") for \"\(query)\" as cards in the chat:"
        out += "\n" + lines.joined(separator: "\n")
        if results.count > top.count {
            out += "\n(\(results.count - top.count) more not shown — refine query if needed)"
        }
        return out
    }

    /// Shared library-list formatter. Caller passes the line transform so
    /// per-arr field selection (tvdbId vs tmdbId vs foreignArtistId vs file
    /// state) stays where it belongs without four near-identical functions.
    private static func formatLibrary<Rec>(
        serviceName: String,
        itemNounSingular: String,
        itemNounPlural: String,
        items: [Rec],
        filter: String,
        line: (Rec) -> String
    ) -> String {
        guard !items.isEmpty else {
            return filter.isEmpty
                ? "\(serviceName) library is empty."
                : "No \(itemNounPlural) in your library match '\(filter)'."
        }
        let top = items.prefix(20)
        let noun = items.count == 1 ? itemNounSingular : itemNounPlural
        var out = "\(serviceName) library — \(items.count) \(noun)"
        if !filter.isEmpty { out += " matching '\(filter)'" }
        out += ":\n" + top.map(line).joined(separator: "\n")
        if items.count > top.count { out += "\n(\(items.count - top.count) more not shown)" }
        return out
    }

    private static func formatArtistSearchCondensed(_ results: [SearchResult], query: String) -> String {
        guard !results.isEmpty else { return "No results found." }
        let top = results.prefix(15)
        let lines = top.map { r -> String in
            let subPart = r.subtitle.map { " (\($0))" } ?? ""
            return "• foreignArtistId=\(r.foreignId) — \(r.title)\(subPart)"
        }
        var out = "Surfaced \(results.count) artist result\(results.count == 1 ? "" : "s") for \"\(query)\" as cards in the chat:"
        out += "\n" + lines.joined(separator: "\n")
        if results.count > top.count {
            out += "\n(\(results.count - top.count) more not shown — refine query if needed)"
        }
        return out
    }

    // MARK: - Whisparr tool implementations

    private func searchScene(_ args: JSONValue) async throws -> ToolCallOutput {
        try await runSearch(args: args, source: .whisparr, config: whisparr, kind: "scene",
                            yearAware: false, rich: { .searchSceneResults($0) })
    }

    private func listScenes(_ args: JSONValue) async throws -> ToolCallOutput {
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

    private func whisparrCalendar() async throws -> ToolCallOutput {
        try await runCalendar(source: .whisparr, config: whisparr) {
            try await WhisparrClient(config: self.whisparr).fetchCalendar()
        }
    }

    private static func formatCalendarCondensed(_ items: [UpcomingItem]) -> String {
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

    // MARK: - TMDB tools

    private func tmdbSearchPerson(_ args: JSONValue) async throws -> ToolCallOutput {
        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else {
            return ToolCallOutput(text: "Please provide a person name to search for.")
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        let results = try await client.searchPerson(query: query)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "No people found on TMDB for '\(query)'.")
        }
        let top = results.prefix(8)
        var out = "Top \(top.count) match\(top.count == 1 ? "" : "es") for '\(query)' (pass personId to tmdb_person_movie_credits or tmdb_person_tv_credits):"
        for p in top {
            let dept = p.knownForDepartment.map { " (\($0))" } ?? ""
            out += "\n- \(p.name)\(dept) — personId: \(p.id)"
        }
        return ToolCallOutput(text: out)
    }

    private func tmdbPersonMovieCredits(_ args: JSONValue) async throws -> ToolCallOutput {
        let personId = Self.intArg(args, key: "personId")
        guard personId != 0 else {
            return ToolCallOutput(text: "Need a personId — run tmdb_search_person first.")
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        let credits = try await client.personMovieCredits(personId: personId)
        // TMDB returns credits unordered. Rank by `popularity` (TMDB's own
        // "what people are searching/watching" metric) descending — voteAverage
        // is misleading here because Sandler's best-rated entries are 7.5+
        // niche cameos with a handful of votes, not Happy Gilmore (6.0, 4k
        // votes). Tie-break on year desc so recent stuff floats.
        let ranked = credits.sorted { lhs, rhs in
            let lp = lhs.popularity ?? 0
            let rp = rhs.popularity ?? 0
            if lp != rp { return lp > rp }
            return (lhs.year ?? 0) > (rhs.year ?? 0)
        }
        let libraryMap = await radarrLibraryByTMDBId()
        let results = Self.tmdbMoviesToSearchResults(ranked.prefix(25), libraryMap: libraryMap)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no movie credits for personId \(personId).")
        }
        let text = Self.formatTMDBSummary(results, kind: "movie", origin: "personId \(personId)")
        return ToolCallOutput(text: text, rich: .searchMovieResults(results))
    }

    private func tmdbPersonTVCredits(_ args: JSONValue) async throws -> ToolCallOutput {
        let personId = Self.intArg(args, key: "personId")
        guard personId != 0 else {
            return ToolCallOutput(text: "Need a personId — run tmdb_search_person first.")
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        let credits = try await client.personTVCredits(personId: personId)
        // Same popularity-desc ranking rationale as the movie path — see
        // tmdbPersonMovieCredits for why voteAverage is the wrong key here.
        let ranked = credits.sorted { lhs, rhs in
            let lp = lhs.popularity ?? 0
            let rp = rhs.popularity ?? 0
            if lp != rp { return lp > rp }
            return (lhs.year ?? 0) > (rhs.year ?? 0)
        }
        let results = Self.tmdbTVToSearchResults(ranked.prefix(25))
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no TV credits for personId \(personId).")
        }
        let text = Self.formatTMDBSummary(results, kind: "series", origin: "personId \(personId)")
        return ToolCallOutput(text: text, rich: .searchSeriesResults(results))
    }

    private func tmdbDiscoverMovies(_ args: JSONValue) async throws -> ToolCallOutput {
        let genreToken = Self.stringArg(args, key: "genre")
        let startYear = Self.optionalIntArg(args, key: "startYear")
        let endYear = Self.optionalIntArg(args, key: "endYear")
        let sortBy = Self.stringArg(args, key: "sortBy")
        let resolvedSort = sortBy.isEmpty ? "popularity.desc" : sortBy
        var genreIds: [Int] = []
        if !genreToken.isEmpty {
            if let id = TMDBGenres.movieId(for: genreToken) {
                genreIds = [id]
            } else {
                return ToolCallOutput(text: "Unknown movie genre '\(genreToken)'. Try: \(Self.knownMovieGenres()).")
            }
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        let movies = try await client.discoverMovies(
            genreIds: genreIds, startYear: startYear, endYear: endYear, sortBy: resolvedSort
        )
        let libraryMap = await radarrLibraryByTMDBId()
        let results = Self.tmdbMoviesToSearchResults(movies.prefix(25), libraryMap: libraryMap)
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no movies matching that filter.")
        }
        let descParts = [
            genreToken.isEmpty ? nil : "genre=\(genreToken)",
            startYear.map { "from \($0)" },
            endYear.map { "to \($0)" },
        ].compactMap { $0 }
        let origin = descParts.isEmpty ? "discover" : descParts.joined(separator: ", ")
        let text = Self.formatTMDBSummary(results, kind: "movie", origin: origin)
        return ToolCallOutput(text: text, rich: .searchMovieResults(results))
    }

    private func tmdbDiscoverSeries(_ args: JSONValue) async throws -> ToolCallOutput {
        let genreToken = Self.stringArg(args, key: "genre")
        let startYear = Self.optionalIntArg(args, key: "startYear")
        let endYear = Self.optionalIntArg(args, key: "endYear")
        let sortBy = Self.stringArg(args, key: "sortBy")
        let resolvedSort = sortBy.isEmpty ? "popularity.desc" : sortBy
        var genreIds: [Int] = []
        if !genreToken.isEmpty {
            if let id = TMDBGenres.tvId(for: genreToken) {
                genreIds = [id]
            } else {
                return ToolCallOutput(text: "Unknown TV genre '\(genreToken)'. Try: \(Self.knownTVGenres()).")
            }
        }
        let client = TMDBClient(apiKey: tmdbApiKey)
        let shows = try await client.discoverTV(
            genreIds: genreIds, startYear: startYear, endYear: endYear, sortBy: resolvedSort
        )
        let results = Self.tmdbTVToSearchResults(shows.prefix(25))
        guard !results.isEmpty else {
            return ToolCallOutput(text: "TMDB returned no series matching that filter.")
        }
        let descParts = [
            genreToken.isEmpty ? nil : "genre=\(genreToken)",
            startYear.map { "from \($0)" },
            endYear.map { "to \($0)" },
        ].compactMap { $0 }
        let origin = descParts.isEmpty ? "discover" : descParts.joined(separator: ", ")
        let text = Self.formatTMDBSummary(results, kind: "series", origin: origin)
        return ToolCallOutput(text: text, rich: .searchSeriesResults(results))
    }

    // MARK: - TMDB → SearchResult adapters

    /// Build `SearchResult`s the rest of the UI already knows how to render
    /// (poster carousel, tap → SearchAddPanel for adds). Movie `id` carries
    /// the tmdbId — Radarr's add path takes it as-is. `libraryMap` maps
    /// tmdbId → Radarr movie id so already-owned results get tagged with
    /// `inLibraryArrId` — the UI then routes the tap to DetailView instead
    /// of the add flow.
    private static func tmdbMoviesToSearchResults(
        _ movies: some Sequence<TMDBMovieSummary>,
        libraryMap: [Int: Int] = [:]
    ) -> [SearchResult] {
        movies.map { m in
            SearchResult(
                id: m.id,
                foreignId: String(m.id),
                title: m.title,
                subtitle: nil,
                year: m.year,
                rating: m.voteAverage,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: m.overview,
                runtime: nil,
                genres: TMDBGenres.movieNames(for: m.genreIds ?? []),
                network: nil,
                certification: nil,
                posterURL: TMDBClient.imageURL(path: m.posterPath),
                source: .radarr,
                inLibraryArrId: libraryMap[m.id]
            )
        }
    }

    /// Build a `tmdbId → movie.id` map of the Radarr library so TMDB-sourced
    /// results can be tagged as "owned" without each result paying for its
    /// own lookup. Returns an empty map if Radarr isn't configured or the
    /// fetch fails — callers should still proceed (owned status just won't be
    /// shown). Demo mode handled by RadarrClient.fetchAllMovies.
    private func radarrLibraryByTMDBId() async -> [Int: Int] {
        guard radarr.isConfigured else { return [:] }
        let client = RadarrClient(config: radarr)
        guard let library = try? await client.fetchAllMovies() else { return [:] }
        var map: [Int: Int] = [:]
        for rec in library {
            if let tmdb = rec.tmdbId, let arrId = rec.id {
                map[tmdb] = arrId
            }
        }
        return map
    }

    /// TV path is fuzzier: Sonarr indexes by tvdbId, but TMDB exposes its own
    /// tv id. We stash 0 in `id` so the add-tap path falls back to a title
    /// lookup — Sonarr resolves the right tvdbId at add-time. Good enough for
    /// popular titles; ambiguous ones surface in SearchAddPanel for review.
    private static func tmdbTVToSearchResults(_ shows: some Sequence<TMDBTVSummary>) -> [SearchResult] {
        shows.map { s in
            SearchResult(
                id: 0,
                foreignId: "",
                title: s.name,
                subtitle: nil,
                year: s.year,
                rating: s.voteAverage,
                imdb: nil, rottenTomatoes: nil, metacritic: nil,
                overview: s.overview,
                runtime: nil,
                genres: TMDBGenres.tvNames(for: s.genreIds ?? []),
                network: nil,
                certification: nil,
                posterURL: TMDBClient.imageURL(path: s.posterPath),
                source: .sonarr
            )
        }
    }

    private static func formatTMDBSummary(_ results: [SearchResult], kind: String, origin: String) -> String {
        let ownedCount = results.filter { $0.inLibraryArrId != nil }.count
        var out = "TMDB returned \(results.count) \(kind) result\(results.count == 1 ? "" : "s") (\(origin))."
        if ownedCount > 0 {
            out += " \(ownedCount) already in the user's library (marked OWNED)."
        }
        out += " Top:"
        for r in results.prefix(15) {
            let year = r.year.map { " (\($0))" } ?? ""
            let rating = r.rating.map { String(format: " ★%.1f", $0) } ?? ""
            let owned = r.inLibraryArrId != nil ? " [OWNED]" : ""
            out += "\n- \(r.title)\(year)\(rating)\(owned) — tmdbId: \(r.id == 0 ? "n/a" : String(r.id))"
        }
        if results.count > 15 { out += "\n…and \(results.count - 15) more." }
        return out
    }

    private static func knownMovieGenres() -> String {
        ["action", "comedy", "crime", "documentary", "drama", "fantasy",
         "horror", "mystery", "romance", "science fiction", "thriller", "western"]
            .joined(separator: ", ")
    }

    private static func knownTVGenres() -> String {
        ["animation", "comedy", "crime", "documentary", "drama",
         "mystery", "reality", "sci-fi & fantasy", "war & politics", "western"]
            .joined(separator: ", ")
    }

    private static func optionalIntArg(_ value: JSONValue, key: String) -> Int? {
        guard case .object(let dict) = value, let v = dict[key] else { return nil }
        switch v {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        case .null: return nil
        default: return nil
        }
    }
}

public enum LocalToolError: Error, Equatable, Sendable, LocalizedError {
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        }
    }
}
