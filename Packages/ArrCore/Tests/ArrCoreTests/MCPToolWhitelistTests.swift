import Testing
@testable import ArrCore

@Suite("MCPToolWhitelist")
struct MCPToolWhitelistTests {
    @Test("add_* are flagged destructive")
    func destructive() {
        #expect(MCPToolWhitelist.isDestructive("sonarr_add_series"))
        #expect(MCPToolWhitelist.isDestructive("radarr_add_movie"))
        #expect(!MCPToolWhitelist.isDestructive("radarr_get_calendar"))
    }

    @Test("search: infix indexer search gates, bare lookup does not")
    func searchSemantics() {
        // Bare `<arr>_search` is a metadata LOOKUP (surfaces add candidates) —
        // read-only, NOT gated.
        #expect(!MCPToolWhitelist.isDestructive("sonarr_search"))
        #expect(!MCPToolWhitelist.isDestructive("radarr_search"))
        #expect(!MCPToolWhitelist.isDestructive("whisparr_search"))
        // Indexer searches (infix) grab releases — gated.
        #expect(MCPToolWhitelist.isDestructive("sonarr_search_episodes"))
        #expect(MCPToolWhitelist.isDestructive("radarr_search_movie"))
        #expect(MCPToolWhitelist.isDestructive("lidarr_search_album"))
        // TMDB read-only lookups have `_search_` in the name but are NOT arr
        // indexer searches — must not be gated.
        #expect(!MCPToolWhitelist.isDestructive("tmdb_search_person"))
        #expect(!MCPToolWhitelist.isDestructive("tmdb_discover_movies"))
    }

    @Test("monitor/add/delete/remove gate as infix and bare suffix")
    func mutatingActions() {
        #expect(MCPToolWhitelist.isDestructive("lidarr_monitor_album"))   // infix
        #expect(MCPToolWhitelist.isDestructive("sonarr_monitor_season"))  // infix
        #expect(MCPToolWhitelist.isDestructive("sonarr_delete"))          // future-proof bare suffix
        #expect(MCPToolWhitelist.isDestructive("radarr_remove"))          // future-proof bare suffix
        // Read-only lookups stay un-gated.
        #expect(!MCPToolWhitelist.isDestructive("sonarr_get_series"))
        #expect(!MCPToolWhitelist.isDestructive("radarr_get_movies"))
    }
}
