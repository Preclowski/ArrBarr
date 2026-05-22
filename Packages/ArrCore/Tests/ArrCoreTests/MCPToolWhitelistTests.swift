import Testing
@testable import ArrCore

@Suite("MCPToolWhitelist")
struct MCPToolWhitelistTests {
    @Test("v1 whitelist exposes exactly the six chosen tools")
    func v1Tools() {
        #expect(MCPToolWhitelist.v1Allowed == Set([
            "sonarr_search",
            "radarr_search",
            "sonarr_get_calendar",
            "radarr_get_calendar",
            "sonarr_add_series",
            "radarr_add_movie",
        ]))
    }

    @Test("add_* are flagged destructive")
    func destructive() {
        #expect(MCPToolWhitelist.isDestructive("sonarr_add_series"))
        #expect(MCPToolWhitelist.isDestructive("radarr_add_movie"))
        #expect(!MCPToolWhitelist.isDestructive("sonarr_search"))
        #expect(!MCPToolWhitelist.isDestructive("radarr_get_calendar"))
    }

    @Test("filter prunes server tools to whitelist preserving order")
    func filter() {
        let server = [
            MCPTool(name: "sonarr_search", description: "", inputSchema: .object([:])),
            MCPTool(name: "trash_list_profiles", description: "", inputSchema: .object([:])),
            MCPTool(name: "radarr_add_movie", description: "", inputSchema: .object([:])),
        ]
        let allowed = MCPToolWhitelist.filter(server)
        #expect(allowed.map(\.name) == ["sonarr_search", "radarr_add_movie"])
    }
}
