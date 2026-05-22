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
        Self.staticTools
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
        let title = Self.stringArg(args, key: "title")
        guard !title.isEmpty else { return "Title is required to add a series." }
        guard sonarr.isConfigured else { return "Sonarr is not configured." }
        let client = SearchClient(config: sonarr, source: .sonarr)
        let candidates = try await client.lookup(query: title)
        guard let first = candidates.first else {
            return "Couldn't find any series matching '\(title)'."
        }
        let profiles = try await client.fetchQualityProfiles()
        let folders = try await client.fetchRootFolders()
        guard let profile = profiles.first, let folder = folders.first else {
            return "Sonarr is missing a quality profile or root folder."
        }
        try await client.addSeries(
            first,
            qualityProfileId: profile.id,
            rootFolderPath: folder.path,
            monitor: .all,
            seriesType: .standard,
            seasonFolder: true
        )
        return "Added '\(first.title)' to Sonarr (profile: \(profile.name), folder: \(folder.path))."
    }

    private func addMovie(_ args: JSONValue) async throws -> String {
        let title = Self.stringArg(args, key: "title")
        guard !title.isEmpty else { return "Title is required to add a movie." }
        guard radarr.isConfigured else { return "Radarr is not configured." }
        let client = SearchClient(config: radarr, source: .radarr)
        let candidates = try await client.lookup(query: title)
        guard let first = candidates.first else {
            return "Couldn't find any movies matching '\(title)'."
        }
        let profiles = try await client.fetchQualityProfiles()
        let folders = try await client.fetchRootFolders()
        guard let profile = profiles.first, let folder = folders.first else {
            return "Radarr is missing a quality profile or root folder."
        }
        try await client.addMovie(
            first,
            qualityProfileId: profile.id,
            rootFolderPath: folder.path,
            monitor: .movieOnly
        )
        return "Added '\(first.title)' to Radarr (profile: \(profile.name), folder: \(folder.path))."
    }

    // MARK: - Formatting helpers

    private static func stringArg(_ value: JSONValue, key: String) -> String {
        if case .object(let dict) = value, case .string(let s) = dict[key] {
            return s
        }
        return ""
    }

    private static func formatSearchResults(_ results: [SearchResult], kind: String) -> String {
        guard !results.isEmpty else { return "No results found." }
        let top = results.prefix(8)
        let lines = top.map { r -> String in
            let yearPart = r.year.map { " (\($0))" } ?? ""
            let ratingPart = r.rating.map { String(format: " · ★ %.1f", $0) } ?? ""
            return "• \(r.title)\(yearPart)\(ratingPart)"
        }
        var out = "Top \(top.count) \(kind) result\(top.count == 1 ? "" : "s"):"
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

    // MARK: - Static tool list

    private static let staticTools: [MCPTool] = [
        MCPTool(
            name: "sonarr_search",
            description: "Search Sonarr for a TV series by title.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Series title or keyword to search for"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        MCPTool(
            name: "radarr_search",
            description: "Search Radarr for a movie by title.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Movie title or keyword to search for"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        MCPTool(
            name: "sonarr_get_calendar",
            description: "Get upcoming TV episode releases from Sonarr.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        MCPTool(
            name: "radarr_get_calendar",
            description: "Get upcoming movie releases from Radarr.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        MCPTool(
            name: "sonarr_add_series",
            description: "Add a TV series to Sonarr by title (will pick the first matching result).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Series title to add"),
                    ]),
                ]),
                "required": .array([.string("title")]),
            ])
        ),
        MCPTool(
            name: "radarr_add_movie",
            description: "Add a movie to Radarr by title (will pick the first matching result).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Movie title to add"),
                    ]),
                ]),
                "required": .array([.string("title")]),
            ])
        ),
    ]
}

public enum LocalToolError: Error, Equatable, Sendable, LocalizedError {
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        }
    }
}
