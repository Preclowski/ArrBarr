import Testing
import Foundation
@testable import ArrCore

/// The tool descriptions are a prompt, and prompts rot silently: a tool gets
/// renamed and three other descriptions keep pointing at the old name, or two
/// tools each claim the same question. The model never complains — it just
/// picks worse. These tests catch the mechanical half of that.
@Suite("Tool catalog consistency")
struct ToolCatalogConsistencyTests {

    private var allTools: [MCPTool] {
        ChatToolCatalog.tools(
            includeSonarr: true, includeRadarr: true, includeLidarr: true,
            includeWhisparr: true, includeTMDBMovies: true, includeTMDBSeries: true,
            includeMediaServer: true
        )
    }

    @Test("Every tool name a description points at actually exists")
    func crossReferencesResolve() {
        let known = Set(ChatToolCatalog.allToolNames)
        // Names as they appear in prose: `radarr_get_movies`, or bare with an
        // underscore. Wildcards (`tmdb_discover_*`, `*_search`) are families,
        // not names, so they're skipped.
        let pattern = try! NSRegularExpression(pattern: "[a-z][a-z0-9]*(?:_[a-z0-9]+)+")
        var dangling: [String] = []
        for tool in allTools {
            let text = tool.description
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                let token = String(text[r])
                // `sonarr_add_*` / `tmdb_discover_*` name a family, and the
                // regex stops at the wildcard — so look at what follows.
                let tail = text[r.upperBound...]
                if tail.hasPrefix("*") || tail.hasPrefix("_*") { continue }
                // Only judge tokens that look like OUR namespace; the prose is
                // full of ordinary snake_case-ish words in other roles.
                let ours = ["sonarr_", "radarr_", "lidarr_", "whisparr_", "tmdb_",
                            "media_server_", "check_", "suggest_", "discover_", "get_", "list_"]
                guard ours.contains(where: { token.hasPrefix($0) }) else { continue }
                // Argument names and prose fragments that share the shape.
                let notTools: Set<String> = ["library_mode", "get_the", "list_of", "check_it",
                                             "media_server", "discover_the"]
                guard !notTools.contains(token), !known.contains(token) else { continue }
                dangling.append("\(tool.name) → \(token)")
            }
        }
        #expect(dangling.isEmpty, "descriptions point at tools that don't exist: \(dangling)")
    }

    @Test("The library tools and check_titles route to each other, not against each other")
    func libraryToolsAgreeOnRouting() throws {
        let byName = Dictionary(uniqueKeysWithValues: allTools.map { ($0.name, $0.description) })
        let check = try #require(byName["check_titles"])
        let movies = try #require(byName["radarr_get_movies"])
        let series = try #require(byName["sonarr_get_series"])
        let history = try #require(byName["media_server_watch_history"])

        // Named titles belong to check_titles, and both list tools say so.
        #expect(movies.contains("check_titles"))
        #expect(series.contains("check_titles"))
        // …and check_titles hands the shelf-browsing case back.
        #expect(check.contains("radarr_get_movies") && check.contains("sonarr_get_series"))
        // Watch history must not claim the "have I seen <named title>" question:
        // it only holds the recent window and would answer it wrongly.
        #expect(history.contains("check_titles"))
    }

    @Test("Every catalog tool is either read-only or deliberately gated")
    func everyToolHasAVerdict() {
        // Not a style check: `isDestructive` is fail-closed, so a tool missing
        // from the allowlist silently stops working for unattended MCP clients.
        // This test makes that a decision rather than an oversight.
        let gated = ChatToolCatalog.allToolNames.filter { MCPToolWhitelist.isDestructive($0) }
        #expect(gated.sorted() == [
            "lidarr_monitor_album",
            "lidarr_search_album",
            "media_server_scan_library",
            "radarr_search_movie",
            "sonarr_monitor_season",
            "sonarr_search_episodes",
        ])
    }
}
