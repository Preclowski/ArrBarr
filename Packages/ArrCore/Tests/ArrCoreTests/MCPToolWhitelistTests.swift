import Testing
@testable import ArrCore

@Suite("MCPToolWhitelist")
struct MCPToolWhitelistTests {
    @Test("add_* are flagged destructive")
    func destructive() {
        #expect(MCPToolWhitelist.isDestructive("sonarr_add_series"))
        #expect(MCPToolWhitelist.isDestructive("radarr_add_movie"))
        #expect(!MCPToolWhitelist.isDestructive("sonarr_search"))
        #expect(!MCPToolWhitelist.isDestructive("radarr_get_calendar"))
    }
}
