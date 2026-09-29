import Foundation
import os
import MediaKit

// MARK: - Destructive-tool confirmation

public enum ToolConfirmationOutcome: Sendable {
    /// Carries the arguments back so a confirm UI could let the user edit them.
    case approved(JSONValue)
    case declined
    /// Nobody could be asked (e.g. an MCP client without elicitation), which is not a refusal.
    case unavailable
}

public typealias ToolConfirmationHandler = @Sendable (ToolCall) async -> ToolConfirmationOutcome

/// Task-local because call sites reach the gate through closures they don't own.
/// Unbound means no user is reachable, so destructive tools are refused (fail-closed).
public enum ToolConfirmationContext {
    @TaskLocal nonisolated public static var handler: ToolConfirmationHandler?
}

/// In-process tool catalog shared by the in-app chat, the MCP server and App Intents.
public actor LocalToolBackend {
    let sonarr: ServiceConfig
    let radarr: ServiceConfig
    let lidarr: ServiceConfig
    let whisparr: ServiceConfig
    let aiKnowsAboutWhisparr: Bool
    let tmdbApiKey: String
    nonisolated var radarrClient: RadarrClient { RadarrClient(config: radarr) }
    nonisolated var sonarrClient: SonarrClient { SonarrClient(config: sonarr) }
    nonisolated var lidarrClient: LidarrClient { LidarrClient(config: lidarr) }
    nonisolated var whisparrClient: WhisparrClient { WhisparrClient(config: whisparr) }
    nonisolated var tmdbClient: TMDBClient { TMDBClient(apiKey: tmdbApiKey) }
    /// Used only by the `health` tool; empty configs are skipped.
    let downloadClients: DownloadClientConfigs
    /// Used only by the `media_server_*` tools.
    let mediaServer: MediaServerConfig

    /// Every caller (chat, MCP, App Intents) passes through here, so the audit trail lives here.
    /// Arguments are never logged: they carry the user's search terms.
    nonisolated private static let log = Logger(category: "Tools")
    nonisolated static let discoverLog = Logger(category: "Quiz")

    /// Stops retries from resurfacing the same lone unowned survivor across calls.
    var surfacedSuggestionIds: Set<String> = []

    /// Built while the model is still streaming `discover_in_quiz` arguments; claimed by the tool call.
    var quizEarlyPipeline: QuizDeckPipeline?
    var quizStreamCloses = 0

    /// MCP server: tools that would open app surfaces (the quiz overlay) return text instead.
    let headlessSurface: Bool

    public init(sonarr: ServiceConfig, radarr: ServiceConfig, lidarr: ServiceConfig = .empty,
                whisparr: ServiceConfig = .empty, aiKnowsAboutWhisparr: Bool = false,
                tmdbApiKey: String = "", downloadClients: DownloadClientConfigs = .init(),
                mediaServer: MediaServerConfig = .empty, headlessSurface: Bool = false) {
        self.headlessSurface = headlessSurface
        self.sonarr = sonarr
        self.radarr = radarr
        self.lidarr = lidarr
        self.whisparr = whisparr
        self.aiKnowsAboutWhisparr = aiKnowsAboutWhisparr
        self.tmdbApiKey = tmdbApiKey
        self.downloadClients = downloadClients
        self.mediaServer = mediaServer
    }

    var tmdbEnabled: Bool { !tmdbApiKey.isEmpty }

    /// The single gate: a tool outside `MCPToolWhitelist.readOnlyTools` never runs without confirmation
    /// through `ToolConfirmationContext`. Call sites decide how to ask, never whether.
    public func callTool(name: String, arguments: JSONValue) async throws -> ToolCallOutput {
        if name.hasPrefix("whisparr_") && !aiKnowsAboutWhisparr {
            return ToolCallOutput(text: "Whisparr AI access is disabled in Settings.")
        }
        // A canned line beats a confirmation prompt for a tool that could only fail.
        if name.hasPrefix("media_server_") && !mediaServer.isConfigured {
            return ToolCallOutput(text: "No media server is configured in Settings → Media server.")
        }
        if name.hasPrefix("tmdb_") && !tmdbEnabled {
            return ToolCallOutput(text: "TMDB API key is not configured in Settings → AI → Discovery.")
        }
        // Unknown names are rejected before any confirmation prompt.
        guard ChatToolCatalog.allToolNames.contains(name) else {
            // Usually a hallucinated name; a catalog/implementation mismatch faults in `run` instead.
            Self.log.notice("tool \(name, privacy: .public): not in the catalog, refused")
            throw LocalToolError.unknownTool(name)
        }
        guard case .object = arguments else { throw LocalToolError.malformedArguments(name) }
        // The guards above run first so switched-off tools never prompt.
        guard MCPToolWhitelist.isDestructive(name) else {
            Self.log.debug("tool \(name, privacy: .public): running (read-only)")
            return try await runLogging(name: name, arguments: arguments)
        }
        guard let confirm = ToolConfirmationContext.handler else {
            Self.log.notice("tool \(name, privacy: .public): destructive, nobody to confirm with — not run")
            throw LocalToolError.confirmationUnavailable(name)
        }
        switch await confirm(ToolCall(name: name, arguments: arguments)) {
        case .approved(let approvedArguments):
            // `.notice` so an approved state-changing call survives in `log show`.
            Self.log.notice("tool \(name, privacy: .public): confirmed, running (destructive)")
            return try await runLogging(name: name, arguments: approvedArguments)
        case .declined:
            Self.log.notice("tool \(name, privacy: .public): declined by the user")
            throw LocalToolError.confirmationDeclined(name)
        case .unavailable:
            Self.log.notice("tool \(name, privacy: .public): destructive, confirmation unavailable — not run")
            throw LocalToolError.confirmationUnavailable(name)
        }
    }

    /// Tool errors otherwise reach only the chat bubble. `.private` because a `URLError`
    /// carries the URL, and SABnzbd's carries `apikey=`.
    private func runLogging(name: String, arguments: JSONValue) async throws -> ToolCallOutput {
        do {
            return try await run(name: name, arguments: arguments)
        } catch {
            Self.log.error(
                "tool \(name, privacy: .public) failed: \(error.logKind, privacy: .public) | \(String(reflecting: error), privacy: .private)"
            )
            throw error
        }
    }

    /// Keyed by catalog name; a test holds this equal to `ChatToolCatalog.allToolNames`.
    /// No add tools: the model surfaces cards and the user adds through `SearchAddPanel`.
    static let handlers: [String: @Sendable (LocalToolBackend, JSONValue) async throws -> ToolCallOutput] = [
        "sonarr_search":              { try await $0.searchSeries($1) },
        "radarr_search":              { try await $0.searchMovie($1) },
        "sonarr_get_series":          { try await $0.listSeries($1) },
        "radarr_get_movies":          { try await $0.listMovies($1) },
        "get_calendar":               { try await $0.getCalendar($1) },
        "lidarr_search":              { try await $0.searchArtist($1) },
        "lidarr_get_artists":         { try await $0.listArtists($1) },
        "whisparr_search":            { try await $0.searchScene($1) },
        "whisparr_get_movies":        { try await $0.listScenes($1) },
        "tmdb_search_person":         { try await $0.tmdbSearchPerson($1) },
        "tmdb_discover_movies":       { try await $0.tmdbDiscoverMovies($1) },
        "tmdb_discover_series":       { try await $0.tmdbDiscoverSeries($1) },
        "suggest_titles":             { try await $0.suggestTitles($1) },
        "check_titles":               { try await $0.checkTitles($1) },
        "discover_in_quiz":           { try await $0.discoverInQuiz($1) },
        "health":                     { backend, _ in try await backend.healthCheck() },
        "get_title_details":          { try await $0.getTitleDetails($1) },
        "custom_formats":             { try await $0.customFormats($1) },
        "list_download_queue":        { try await $0.listDownloadQueue($1) },
        "sonarr_monitor_season":      { try await $0.sonarrMonitorSeason($1) },
        "sonarr_search_episodes":     { try await $0.sonarrSearchEpisodesTool($1) },
        "radarr_search_movie":        { try await $0.radarrSearchMovieTool($1) },
        "lidarr_get_artist_albums":   { try await $0.lidarrGetArtistAlbums($1) },
        "lidarr_monitor_album":       { try await $0.lidarrMonitorAlbum($1) },
        "lidarr_search_album":        { try await $0.lidarrSearchAlbumTool($1) },
        "media_server_watch_history": { try await $0.mediaServerWatchHistory($1) },
        "media_server_now_playing":   { backend, _ in try await backend.mediaServerNowPlaying() },
        "media_server_scan_library":  { backend, _ in try await backend.mediaServerScanLibrary() },
    ]

    /// Private so `callTool`'s gate is the only way in.
    private func run(name: String, arguments: JSONValue) async throws -> ToolCallOutput {
        guard let handler = Self.handlers[name] else {
            // `.fault`: the catalog advertises a tool nobody implemented.
            Self.log.fault("tool \(name, privacy: .public) is in the catalog but has no implementation")
            throw LocalToolError.unknownTool(name)
        }
        return try await handler(self, arguments)
    }

    // MARK: - Generic helpers — collapse the per-arr handler boilerplate

    /// Shared `*_search` shape; Lidarr uses `runSearchArtist` (different formatter and rich case).
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
        let query = LibraryQuery(title: filter)
        let shown = filter.isEmpty ? LibraryFilter.sample(matched, count: Self.librarySampleSize) : Array(matched.prefix(Self.libraryRowCap))
        let text = libraryText(
            serviceName: source.displayName, noun: itemNounSingular, nounPlural: itemNounPlural,
            total: all.count, matched: matched.count, shown: shown, query: query, nearest: [],
            line: line, nearestLine: line
        )
        return ToolCallOutput(text: text, rich: rich(shown))
    }


    // MARK: - Formatting helpers

    nonisolated static func stringArg(_ value: JSONValue, key: String) -> String {
        if case .object(let dict) = value, case .string(let s) = dict[key] {
            return s
        }
        return ""
    }

    /// Accepts JSON numbers or strings: models sometimes send "12345".
    nonisolated static func intArg(_ value: JSONValue, key: String) -> Int {
        guard case .object(let dict) = value, let v = dict[key] else { return 0 }
        switch v {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s) ?? 0
        default: return 0
        }
    }

    /// Distinguishes absent from zero, for tools where 0 is valid (season number).
    nonisolated static func optionalIntArg(_ value: JSONValue, key: String) -> Int? {
        guard case .object(let dict) = value, let v = dict[key] else { return nil }
        switch v {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    nonisolated static func optionalBoolArg(_ value: JSONValue, key: String) -> Bool? {
        guard case .object(let dict) = value, let v = dict[key] else { return nil }
        switch v {
        case .bool(let b): return b
        case .string(let s): return Bool(s)
        default: return nil
        }
    }

    nonisolated static func intArrayArg(_ value: JSONValue, key: String) -> [Int] {
        guard case .object(let dict) = value, case .array(let arr) = dict[key] else { return [] }
        return arr.compactMap { entry -> Int? in
            switch entry {
            case .number(let n): return Int(n)
            case .string(let s): return Int(s)
            default: return nil
            }
        }
    }

    /// No overview or ratings: the carousel shows those.
    nonisolated static func formatSearchResultsCondensed(
        _ results: [SearchResult],
        query: String,
        kind: String
    ) -> String {
        guard !results.isEmpty else {
            // A bare "No results" invites the model to rephrase and retry repeatedly; one miss is the answer.
            var out = "No \(kind) results for \"\(query)\". One miss is the answer — do NOT retry this tool with rephrasings of the same title."
            switch kind {
            case "series":
                out += " If this could be a FILM, try radarr_search ONCE — anime features (Ghibli, Satoshi Kon) are movies, not series. And if the user asked ABOUT the title (plot, trivia, 'tell me about X'), no search tool is needed at all: answer from your own knowledge."
            case "movie":
                out += " If this could be a SERIES, try sonarr_search ONCE. And if the user asked ABOUT the title (plot, trivia, 'tell me about X'), no search tool is needed at all: answer from your own knowledge."
            default:
                break
            }
            return out
        }
        let top = results.prefix(15)
        let lines = top.map { r -> String in
            let yearPart = r.year.map { " (\($0))" } ?? ""
            // Without the ref on every line, the model invents ids when asked to link a title.
            let ref = r.mediaRef.isAddressable ? " — \(r.mediaRef.urlString)" : ""
            return "• \(r.title)\(yearPart)\(ref)"
        }
        var out = "Surfaced \(results.count) \(kind) result\(results.count == 1 ? "" : "s") for \"\(query)\" as cards in the chat:"
        out += "\n" + lines.joined(separator: "\n")
        if results.count > top.count {
            out += "\n(\(results.count - top.count) more not shown — refine query if needed)"
        }
        return out
    }

    nonisolated static func formatArtistSearchCondensed(_ results: [SearchResult], query: String) -> String {
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

/// Each defaults to `.empty` (skipped).
nonisolated public struct DownloadClientConfigs: Sendable, Equatable {
    public var qbittorrent: ServiceConfig
    public var transmission: ServiceConfig
    public var nzbget: ServiceConfig
    public var sabnzbd: ServiceConfig
    public var rtorrent: ServiceConfig
    public var deluge: ServiceConfig

    public init(
        qbittorrent: ServiceConfig = .empty,
        transmission: ServiceConfig = .empty,
        nzbget: ServiceConfig = .empty,
        sabnzbd: ServiceConfig = .empty,
        rtorrent: ServiceConfig = .empty,
        deluge: ServiceConfig = .empty
    ) {
        self.qbittorrent = qbittorrent
        self.transmission = transmission
        self.nzbget = nzbget
        self.sabnzbd = sabnzbd
        self.rtorrent = rtorrent
        self.deluge = deluge
    }
}

public enum LocalToolError: Error, Equatable, Sendable, LocalizedError {
    case unknownTool(String)
    case confirmationDeclined(String)
    /// No handler bound, or the caller cannot prompt. The tool did not run.
    case confirmationUnavailable(String)
    case malformedArguments(String)

    // Plain English, not the catalog: these go to the LLM / MCP client as tool output.
    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .confirmationDeclined(let name):
            return "Tool '\(name)' was cancelled by the user."
        case .confirmationUnavailable(let name):
            return "Tool '\(name)' changes server state and requires confirmation, which was not available. It was not run."
        case .malformedArguments(let name):
            return "Arguments for '\(name)' were not a valid JSON object. It was not run; call it again with a JSON object matching its schema."
        }
    }
}
