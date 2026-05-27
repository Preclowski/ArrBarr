import Foundation

/// In-process tool backend. Uses ArrCore's existing Sonarr/Radarr clients.
/// Exposes the same 6 tools as mcp-arr, but with zero external dependencies.
public actor LocalToolBackend: ToolBackend {
    let sonarr: ServiceConfig
    let radarr: ServiceConfig
    let lidarr: ServiceConfig
    let whisparr: ServiceConfig
    let aiKnowsAboutWhisparr: Bool
    let tmdbApiKey: String

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

    var tmdbEnabled: Bool { !tmdbApiKey.isEmpty }

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
        case "discover_in_quiz":            return try await discoverInQuiz(arguments)
        case "arr_health":                  return try await arrHealth()
        case "sonarr_monitor_season":       return try await sonarrMonitorSeason(arguments)
        case "sonarr_search_episodes":      return try await sonarrSearchEpisodesTool(arguments)
        case "radarr_search_movie":         return try await radarrSearchMovieTool(arguments)
        case "lidarr_get_artist_albums":    return try await lidarrGetArtistAlbums(arguments)
        case "lidarr_monitor_album":        return try await lidarrMonitorAlbum(arguments)
        case "lidarr_search_album":         return try await lidarrSearchAlbumTool(arguments)
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
    func runSearch(
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

    func runSearchArtist(args: JSONValue) async throws -> ToolCallOutput {
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
    func runLibraryList<Rec>(
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
    func runCalendar(
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

    // MARK: - Formatting helpers

    static func stringArg(_ value: JSONValue, key: String) -> String {
        if case .object(let dict) = value, case .string(let s) = dict[key] {
            return s
        }
        return ""
    }

    /// Extract an integer arg. Tolerates JSON numbers OR strings (LLM might
    /// serialize "12345" instead of 12345).
    static func intArg(_ value: JSONValue, key: String) -> Int {
        guard case .object(let dict) = value, let v = dict[key] else { return 0 }
        switch v {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s) ?? 0
        default: return 0
        }
    }

    /// Like `intArg` but distinguishes "absent" from "zero". Used by
    /// tools where 0 is a legitimate value (season number, etc.).
    static func optionalIntArg(_ value: JSONValue, key: String) -> Int? {
        guard case .object(let dict) = value, let v = dict[key] else { return nil }
        switch v {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    /// Bool arg parser. Defaults to `nil` when absent so callers can
    /// distinguish "missing" from "explicit false".
    static func optionalBoolArg(_ value: JSONValue, key: String) -> Bool? {
        guard case .object(let dict) = value, let v = dict[key] else { return nil }
        switch v {
        case .bool(let b): return b
        case .string(let s): return Bool(s)
        default: return nil
        }
    }

    /// Pull `[Int]` out of a JSON-RPC arguments object.
    static func intArrayArg(_ value: JSONValue, key: String) -> [Int] {
        guard case .object(let dict) = value, case .array(let arr) = dict[key] else { return [] }
        return arr.compactMap { entry -> Int? in
            switch entry {
            case .number(let n): return Int(n)
            case .string(let s): return Int(s)
            default: return nil
            }
        }
    }

    /// Condensed search result text for the LLM — id + title + year only.
    /// No overview, no rating, no year-match markers (the carousel makes those visible).
    static func formatSearchResultsCondensed(
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
    static func formatLibrary<Rec>(
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

    static func formatArtistSearchCondensed(_ results: [SearchResult], query: String) -> String {
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

}

public enum LocalToolError: Error, Equatable, Sendable, LocalizedError {
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        }
    }
}
