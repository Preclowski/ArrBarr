import Testing
@testable import ArrCore

@Suite("MCPToolWhitelist")
struct MCPToolWhitelistTests {
    /// The gate is an ALLOWLIST now, not a denylist of name patterns, so the
    /// headline property is that an unrecognised name gates. The old rules
    /// keyed off `_add_` / `_delete` / `_remove` spellings; those names are
    /// still gated, but because nothing vouched for them, not because their
    /// spelling matched.
    @Test("an unrecognised tool name is gated (fail-closed)")
    func unknownNamesGate() {
        // Names we don't ship at all.
        #expect(MCPToolWhitelist.isDestructive("sonarr_add_series"))
        #expect(MCPToolWhitelist.isDestructive("radarr_add_movie"))
        #expect(MCPToolWhitelist.isDestructive("queue_purge"))
        // Nearly-right spelling of a real read-only tool. Under the old
        // denylist this ran unconfirmed; the point of failing closed is that a
        // typo costs a confirmation prompt rather than an unattended mutation.
        #expect(MCPToolWhitelist.isDestructive("radarr_get_calendar"))
        // …and the tool it was almost the name of is genuinely read-only.
        #expect(!MCPToolWhitelist.isDestructive("get_calendar"))
    }

    @Test("search: indexer search gates, bare metadata lookup does not")
    func searchSemantics() {
        // Bare `<arr>_search` is a metadata LOOKUP (surfaces add candidates) —
        // read-only, NOT gated.
        #expect(!MCPToolWhitelist.isDestructive("sonarr_search"))
        #expect(!MCPToolWhitelist.isDestructive("radarr_search"))
        #expect(!MCPToolWhitelist.isDestructive("whisparr_search"))
        // Indexer searches grab releases — gated.
        #expect(MCPToolWhitelist.isDestructive("sonarr_search_episodes"))
        #expect(MCPToolWhitelist.isDestructive("radarr_search_movie"))
        #expect(MCPToolWhitelist.isDestructive("lidarr_search_album"))
        // TMDB lookups have `_search_` in the name but hit no indexer.
        #expect(!MCPToolWhitelist.isDestructive("tmdb_search_person"))
        #expect(!MCPToolWhitelist.isDestructive("tmdb_discover_movies"))
    }

    @Test("monitor tools gate, library reads do not")
    func mutatingActions() {
        // Monitoring fires an immediate season/album search — a grab.
        #expect(MCPToolWhitelist.isDestructive("lidarr_monitor_album"))
        #expect(MCPToolWhitelist.isDestructive("sonarr_monitor_season"))
        // Read-only lookups stay un-gated.
        #expect(!MCPToolWhitelist.isDestructive("sonarr_get_series"))
        #expect(!MCPToolWhitelist.isDestructive("radarr_get_movies"))
    }

    /// The allowlist is spelled out by hand, so the failure mode it invites is
    /// a name that matches no shipping tool: harmless-looking, but it means the
    /// tool it was meant to vouch for is silently gated instead. Fail-closed
    /// hides that — the tool still refuses to run — so pin it here.
    @Test("every allowlisted name exists in the tool catalog")
    func allowlistHasNoPhantomNames() {
        let catalog = Set(ChatToolCatalog.allToolNames)
        let phantoms = MCPToolWhitelist.readOnlyTools.subtracting(catalog)
        #expect(phantoms.isEmpty, "readOnlyTools names no shipping tool: \(phantoms.sorted())")
    }
}
