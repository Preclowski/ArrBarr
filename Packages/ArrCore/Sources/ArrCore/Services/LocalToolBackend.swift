import Foundation
import os

// MARK: - Destructive-tool confirmation

/// How the caller's user answered the confirmation prompt for a gated tool.
public enum ToolConfirmationOutcome: Sendable {
    /// Approved — run with these arguments. Handing the arguments back (rather
    /// than a bare `true`) leaves room for a confirm UI that lets the user edit
    /// them before the call goes out; none does today.
    case approved(JSONValue)
    /// The user said no.
    case declined
    /// Nobody could be asked. Distinct from `.declined` because the caller may
    /// want to explain itself differently — an MCP client that never advertised
    /// elicitation isn't a user refusing, it's a client that cannot ask.
    case unavailable
}

/// Asks whoever is driving a tool call to confirm a destructive one.
public typealias ToolConfirmationHandler = @Sendable (ToolCall) async -> ToolConfirmationOutcome

/// Ambient confirmation channel for the current task.
///
/// The gate lives in `LocalToolBackend.callTool`, but the call sites reach it
/// through closures whose signatures they don't own (`ChatViewModelFactory`
/// hands both chat providers a plain `(name, args)` passthrough), so the
/// handler travels as a task-local rather than a parameter. Every call site
/// binds it immediately around its own call, so the value never has to survive
/// a framework we don't control.
///
/// Unbound — the default — means "no user is reachable", and the gate then
/// refuses every destructive tool. That is the fail-closed direction: a call
/// site that forgets to bind a handler loses the ability to mutate, it does not
/// silently gain the ability to mutate unconfirmed.
public enum ToolConfirmationContext {
    @TaskLocal public static var handler: ToolConfirmationHandler?
}

/// In-process tool backend. Uses ArrCore's existing Sonarr/Radarr clients.
/// Exposes the same 6 tools as mcp-arr, but with zero external dependencies.
public actor LocalToolBackend: ToolBackend {
    let sonarr: ServiceConfig
    let radarr: ServiceConfig
    let lidarr: ServiceConfig
    let whisparr: ServiceConfig
    let aiKnowsAboutWhisparr: Bool
    let tmdbApiKey: String
    /// Download-client connection configs, used by the `health` tool to
    /// report reachability of qBittorrent/Transmission/etc. Empty configs
    /// are skipped. Not needed by any other tool, so it defaults to none.
    let downloadClients: DownloadClientConfigs
    /// The one media server, when connected. Drives the `media_server_*` tools
    /// and nothing else — no other tool consults it.
    let mediaServer: MediaServerConfig

    /// Every tool call the app runs passes through here, whoever asked — chat,
    /// MCP, App Intents — so this is where the audit trail belongs. The MCP
    /// server logs its own `tools/call` on the way in, which covers only one of
    /// the three callers; this covers all of them and, unlike that one, sees
    /// how the call ended.
    ///
    /// Tool *arguments* are never logged: they carry the user's search terms
    /// and, through them, the shape of their library. The name plus the outcome
    /// is what a support question actually needs.
    private static let log = Logger(category: "Tools")

    /// True when this backend serves a caller with no ArrBarr UI in front of
    /// it (the MCP server): tools that would otherwise drive the app's own
    /// surfaces (opening the quiz overlay) return their data as text instead
    /// of popping windows the remote client cannot see.
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

    public func listTools() async throws -> [MCPTool] {
        ChatToolCatalog.tools(
            includeSonarr: sonarr.isConfigured,
            includeRadarr: radarr.isConfigured,
            includeLidarr: lidarr.isConfigured,
            includeWhisparr: whisparr.isConfigured && aiKnowsAboutWhisparr,
            includeTMDBMovies: tmdbEnabled && radarr.isConfigured,
            includeTMDBSeries: tmdbEnabled && sonarr.isConfigured,
            includeMediaServer: mediaServer.isConfigured
        )
    }

    /// THE choke point. Every tool call — chat (OpenAI or Foundation Models),
    /// MCP server, App Intents — lands here, and a tool that isn't on
    /// `MCPToolWhitelist.readOnlyTools` does not execute without an explicit
    /// user confirmation obtained through `ToolConfirmationContext`.
    ///
    /// The gate used to be re-implemented at each of the three call sites,
    /// which meant a new call site that forgot it bypassed the gate entirely.
    /// Call sites still decide HOW to ask (confirm card / MCP elicitation);
    /// deciding WHETHER to ask, and refusing when the answer never comes, is
    /// this method's job alone.
    public func callTool(name: String, arguments: JSONValue) async throws -> ToolCallOutput {
        // Guard Whisparr tools when the toggle is off
        if name.hasPrefix("whisparr_") && !aiKnowsAboutWhisparr {
            return ToolCallOutput(text: "Whisparr AI access is disabled in Settings.")
        }
        // Guard media-server tools when nothing is connected — same shape as
        // the TMDB guard: a canned line beats a confirmation prompt for a tool
        // that could only fail.
        if name.hasPrefix("media_server_") && !mediaServer.isConfigured {
            return ToolCallOutput(text: "No media server is configured in Settings → Media server.")
        }
        // Guard TMDB tools when no key is configured
        if name.hasPrefix("tmdb_") && !tmdbEnabled {
            return ToolCallOutput(text: "TMDB API key is not configured in Settings → AI → Discovery.")
        }
        // A name we don't implement can't run whatever the user answers, so
        // reject it plainly instead of raising a confirmation for a tool that
        // doesn't exist. Still fail-closed — nothing executes either way.
        guard ChatToolCatalog.allToolNames.contains(name) else {
            // The catalog is ours and the caller picked from it, so a name
            // outside it means a model hallucinated one — expected — or the
            // catalog and this file disagree. Only the second is our bug, and
            // `run`'s backstop is where that one surfaces as a fault.
            Self.log.notice("tool \(name, privacy: .public): not in the catalog, refused")
            throw LocalToolError.unknownTool(name)
        }
        // Read-only tools run straight through — that is the whole point of
        // keeping the allowlist tight. Everything else has to be confirmed.
        // The guards above run first so we never prompt for a tool that is
        // switched off and would only return a canned "not configured" line.
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
            // The one line worth keeping: a state-changing call the user
            // approved. `.notice` so "what did the AI actually do to my
            // library an hour ago" survives in `log show`.
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

    /// `run`, plus the failure half of the audit trail.
    ///
    /// A tool that throws surfaces to the caller as prose in the chat bubble
    /// ("(tool error: …)") and nowhere else, so without this the interesting
    /// half — which arr, what kind of failure — has no route out of the app.
    /// The error is `.private`: a `URLError` carries the failing URL, and for
    /// SABnzbd that URL carries `apikey=` (same reasoning as `QueueAggregator`).
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

    /// Dispatch to the actual implementation. Private so the gate above is the
    /// only way in — an extension or a future call site cannot reach past it.
    private func run(name: String, arguments: JSONValue) async throws -> ToolCallOutput {
        switch name {
        case "sonarr_search":       return try await searchSeries(arguments)
        case "radarr_search":       return try await searchMovie(arguments)
        case "sonarr_get_series":   return try await listSeries(arguments)
        case "radarr_get_movies":   return try await listMovies(arguments)
        case "get_calendar":        return try await getCalendar(arguments)
        // `*_add_*` tools used to live here. Removed in favour of "model
        // surfaces, user adds via the SearchAddPanel card flow" — see
        // ChatToolCatalog for the rationale. The model now drops the user
        // off at a tappable card; tapping opens the same panel `+` uses,
        // with profile/folder/quality pickers and a single confirm button.
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
            // `callTool` already rejected anything outside the directory, so
            // reaching here means the directory lists a tool this switch never
            // implemented. Same error, deliberate backstop — and a `.fault`,
            // because unlike an invented tool name this one is our bug: the
            // catalog advertised something the app cannot do.
            Self.log.fault("tool \(name, privacy: .public) is in the catalog but has no implementation")
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
        guard !results.isEmpty else {
            // A bare "No results found." reads as an invitation to rephrase
            // and retry — models will happily do that five times in a row.
            // One miss IS the answer; say so, and name the two ways a miss
            // is usually a routing mistake instead.
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
            // The external ref rides along on every line. Without it the model
            // has no id for a title it is about to name in prose — and asked to
            // link that title, it will reach into memory and invent one.
            let ref = r.mediaRef.isAddressable ? " — \(r.mediaRef.urlString)" : ""
            return "• \(r.title)\(yearPart)\(ref)"
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

/// Which download client a health probe targets. Plain Sendable enum so it
/// can cross the `health` tool's parallel task group without closures.
enum DownloadClientKind: Sendable {
    case qbittorrent, transmission, nzbget, sabnzbd, rtorrent, deluge
}

/// The six download-client connection configs the `health` tool can probe.
/// Each defaults to `.empty` (skipped) so callers only fill what's set up.
public struct DownloadClientConfigs: Sendable {
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
    /// The user was asked to confirm a destructive tool and said no.
    case confirmationDeclined(String)
    /// A destructive tool was requested with no way to ask the user — no
    /// handler bound, or the caller reported it cannot prompt. The tool did
    /// not run.
    case confirmationUnavailable(String)

    // Plain English on purpose: these strings go to the LLM / an MCP client
    // as tool-call text, not into the app's own UI, so they live outside the
    // string catalog like the rest of the tool output in this file.
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
