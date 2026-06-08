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

    @Test("bare trailing action suffixes are flagged destructive")
    func trailingSuffixes() {
        // Catalog tools named with a bare trailing action word (no infix
        // underscore) must still gate — `sonarr_search` kicks off a grab.
        #expect(MCPToolWhitelist.isDestructive("sonarr_search"))
        #expect(MCPToolWhitelist.isDestructive("radarr_search"))
        #expect(MCPToolWhitelist.isDestructive("lidarr_monitor_album"))
        #expect(MCPToolWhitelist.isDestructive("whisparr_search"))
        // Read-only lookups stay un-gated.
        #expect(!MCPToolWhitelist.isDestructive("sonarr_get_series"))
        #expect(!MCPToolWhitelist.isDestructive("radarr_get_movies"))
    }
}
