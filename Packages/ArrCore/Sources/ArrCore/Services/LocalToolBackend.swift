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
                "tool \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public) | \(String(reflecting: error), privacy: .private)"
            )
            throw error
        }
    }

    /// Private so `callTool`'s gate is the only way in.
    private func run(name: String, arguments: JSONValue) async throws -> ToolCallOutput {
        switch name {
        case "sonarr_search":       return try await searchSeries(arguments)
        case "radarr_search":       return try await searchMovie(arguments)
        case "sonarr_get_series":   return try await listSeries(arguments)
        case "radarr_get_movies":   return try await listMovies(arguments)
        case "get_calendar":        return try await getCalendar(arguments)
        // No add tools: the model surfaces cards and the user adds through `SearchAddPanel`.
        case "lidarr_search":       return try await searchArtist(arguments)
        case "lidarr_get_artists":  return try await listArtists(arguments)
        case "whisparr_search":     return try await searchScene(arguments)
        case "whisparr_get_movies": return try await listScenes(arguments)
        case "tmdb_search_person":          return try await tmdbSearchPerson(arguments)
        case "tmdb_person_movie_credits":   return try await tmdbPersonMovieCredits(arguments)
        case "tmdb_person_tv_credits":      return try await tmdbPersonTVCredits(arguments)
        case "tmdb_discover_movies":        return try await tmdbDiscoverMovies(arguments)
        case "tmdb_discover_series":        return try await tmdbDiscoverSeries(arguments)
        case "suggest_titles":              return try await suggestTitles(arguments)
        case "check_titles":                return try await checkTitles(arguments)
        case "discover_in_quiz":            return try await discoverInQuiz(arguments)
        case "health":                      return try await healthCheck()
        case "get_title_details":           return try await getTitleDetails(arguments)
        case "custom_formats":              return try await customFormats(arguments)
        case "list_download_queue":         return try await listDownloadQueue(arguments)
        case "sonarr_monitor_season":       return try await sonarrMonitorSeason(arguments)
        case "sonarr_search_episodes":      return try await sonarrSearchEpisodesTool(arguments)
        case "radarr_search_movie":         return try await radarrSearchMovieTool(arguments)
        case "lidarr_get_artist_albums":    return try await lidarrGetArtistAlbums(arguments)
        case "lidarr_monitor_album":        return try await lidarrMonitorAlbum(arguments)
        case "lidarr_search_album":         return try await lidarrSearchAlbumTool(arguments)
        case "media_server_watch_history":  return try await mediaServerWatchHistory(arguments)
        case "media_server_now_playing":    return try await mediaServerNowPlaying()
        case "media_server_scan_library":   return try await mediaServerScanLibrary()
        default:
            // `.fault`: the catalog advertises a tool this switch never implemented.
            Self.log.fault("tool \(name, privacy: .public) is in the catalog but has no implementation")
            throw LocalToolError.unknownTool(name)
        }
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

/// Plain Sendable enum so it crosses the `health` tool's task group without closures.
enum DownloadClientKind: Sendable {
    case qbittorrent, transmission, nzbget, sabnzbd, rtorrent, deluge
}

/// Each defaults to `.empty` (skipped).
nonisolated public struct DownloadClientConfigs: Sendable {
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

    // Plain English, not the catalog: these go to the LLM / MCP client as tool output.
    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .confirmationDeclined(let name):
            return "Tool '\(name)' was cancelled by the user."
        case .confirmationUnavailable(let name):
            return "Tool '\(name)' changes server state and requires confirmation, which was not available. It was not run."
        }
    }
}
