import Foundation

/// In-process tool backend. Uses ArrCore's existing Sonarr/Radarr clients.
/// Exposes the same 6 tools as mcp-arr, but with zero external dependencies.
public actor LocalToolBackend: ToolBackend {
    private let sonarr: ServiceConfig
    private let radarr: ServiceConfig

    public init(sonarr: ServiceConfig, radarr: ServiceConfig) {
        self.sonarr = sonarr
        self.radarr = radarr
    }

    public func listTools() async throws -> [MCPTool] {
        ChatToolCatalog.tools
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> String {
        switch name {
        case "sonarr_search":       return try await searchSeries(arguments)
        case "radarr_search":       return try await searchMovie(arguments)
        case "sonarr_get_calendar": return try await sonarrCalendar()
        case "radarr_get_calendar": return try await radarrCalendar()
        case "sonarr_add_series":   return try await addSeries(arguments)
        case "radarr_add_movie":    return try await addMovie(arguments)
        default:
            throw LocalToolError.unknownTool(name)
        }
    }

    // MARK: - Tool implementations

    private func searchSeries(_ args: JSONValue) async throws -> String {
        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else { return "Please provide a search query." }
        guard sonarr.isConfigured else { return "Sonarr is not configured." }
        let client = SearchClient(config: sonarr, source: .sonarr)
        let results = try await client.lookup(query: query)
        return Self.formatSearchResults(results, kind: "series")
    }

    private func searchMovie(_ args: JSONValue) async throws -> String {
        let query = Self.stringArg(args, key: "query")
        guard !query.isEmpty else { return "Please provide a search query." }
        guard radarr.isConfigured else { return "Radarr is not configured." }
        let client = SearchClient(config: radarr, source: .radarr)
        let results = try await client.lookup(query: query)
        return Self.formatSearchResults(results, kind: "movie")
    }

    private func sonarrCalendar() async throws -> String {
        guard sonarr.isConfigured else { return "Sonarr is not configured." }
        let client = SonarrClient(config: sonarr)
        let items = try await client.fetchCalendar()
        return Self.formatCalendar(items)
    }

    private func radarrCalendar() async throws -> String {
        guard radarr.isConfigured else { return "Radarr is not configured." }
        let client = RadarrClient(config: radarr)
        let items = try await client.fetchCalendar()
        return Self.formatCalendar(items)
    }

    private func addSeries(_ args: JSONValue) async throws -> String {
        let tvdbId = Self.intArg(args, key: "tvdbId")
        let title = Self.stringArg(args, key: "title")
        guard tvdbId != 0 || !title.isEmpty else {
            return "Need a tvdbId (preferred) or title to add a series. Run sonarr_search first."
        }
        guard sonarr.isConfigured else { return "Sonarr is not configured." }
        let client = SearchClient(config: sonarr, source: .sonarr)
        // Lookup once. We accept either tvdbId (exact) or title (search + pick).
        let lookupQuery = tvdbId != 0 ? "tvdb:\(tvdbId)" : title
        let candidates = try await client.lookup(query: lookupQuery)
        // If the user / LLM supplied tvdbId, demand an exact match before we add.
        let chosen: SearchResult?
        if tvdbId != 0 {
            chosen = candidates.first(where: { $0.id == tvdbId }) ?? candidates.first
        } else {
            chosen = candidates.first
        }
        guard let pick = chosen else {
            return "Couldn't find any series matching '\(lookupQuery)'."
        }
        let profiles = try await client.fetchQualityProfiles()
        let folders = try await client.fetchRootFolders()
        guard let profile = profiles.first, let folder = folders.first else {
            return "Sonarr is missing a quality profile or root folder."
        }
        try await client.addSeries(
            pick,
            qualityProfileId: profile.id,
            rootFolderPath: folder.path,
            monitor: .all,
            seriesType: .standard,
            seasonFolder: true
        )
        let yearPart = pick.year.map { " (\($0))" } ?? ""
        return "Added '\(pick.title)\(yearPart)' to Sonarr (profile: \(profile.name), folder: \(folder.path))."
    }

    private func addMovie(_ args: JSONValue) async throws -> String {
        let tmdbId = Self.intArg(args, key: "tmdbId")
        let title = Self.stringArg(args, key: "title")
        guard tmdbId != 0 || !title.isEmpty else {
            return "Need a tmdbId (preferred) or title to add a movie. Run radarr_search first."
        }
        guard radarr.isConfigured else { return "Radarr is not configured." }
        let client = SearchClient(config: radarr, source: .radarr)
        let lookupQuery = tmdbId != 0 ? "tmdb:\(tmdbId)" : title
        let candidates = try await client.lookup(query: lookupQuery)
        let chosen: SearchResult?
        if tmdbId != 0 {
            chosen = candidates.first(where: { $0.id == tmdbId }) ?? candidates.first
        } else {
            chosen = candidates.first
        }
        guard let pick = chosen else {
            return "Couldn't find any movies matching '\(lookupQuery)'."
        }
        let profiles = try await client.fetchQualityProfiles()
        let folders = try await client.fetchRootFolders()
        guard let profile = profiles.first, let folder = folders.first else {
            return "Radarr is missing a quality profile or root folder."
        }
        try await client.addMovie(
            pick,
            qualityProfileId: profile.id,
            rootFolderPath: folder.path,
            monitor: .movieOnly
        )
        let yearPart = pick.year.map { " (\($0))" } ?? ""
        return "Added '\(pick.title)\(yearPart)' to Radarr (profile: \(profile.name), folder: \(folder.path))."
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

    private static func formatSearchResults(_ results: [SearchResult], kind: String) -> String {
        guard !results.isEmpty else { return "No results found." }
        let top = results.prefix(8)
        // For series the id is tvdbId; for movies it's tmdbId. The label
        // helps the LLM pick the right arg name when calling *_add_*.
        let idLabel = kind == "series" ? "tvdbId" : "tmdbId"
        let lines = top.map { r -> String in
            let yearPart = r.year.map { " (\($0))" } ?? ""
            let ratingPart = r.rating.map { String(format: " · ★ %.1f", $0) } ?? ""
            return "• \(idLabel)=\(r.id) — \(r.title)\(yearPart)\(ratingPart)"
        }
        var out = "Top \(top.count) \(kind) result\(top.count == 1 ? "" : "s") (use \(idLabel) when calling add):"
        out += "\n" + lines.joined(separator: "\n")
        if results.count > top.count {
            out += "\n(\(results.count - top.count) more not shown)"
        }
        return out
    }

    private static func formatCalendar(_ items: [UpcomingItem]) -> String {
        guard !items.isEmpty else { return "Nothing upcoming." }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        let top = items.prefix(15)
        let lines = top.map { it -> String in
            let dateStr = fmt.string(from: it.airDate)
            if let subtitle = it.subtitle, !subtitle.isEmpty {
                return "• \(dateStr) — \(it.title) (\(subtitle))"
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

public enum LocalToolError: Error, Equatable, Sendable, LocalizedError {
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        }
    }
}
