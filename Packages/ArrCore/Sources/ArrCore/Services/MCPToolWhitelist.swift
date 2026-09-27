import Foundation

/// Destructive-action gating: a tool not on the read-only allowlist needs a human yes (chat card or MCP
/// elicitation). An allowlist, not a denylist, so a newly added tool stays gated until vouched for.
nonisolated public enum MCPToolWhitelist {

    /// Spelled out by name so growing the catalog never widens what an unattended MCP client may run.
    /// Bare `<arr>_search` tools are metadata lookups; `*_search_*` and `*_monitor_*` hit indexers and stay gated.
    public static let readOnlyTools: Set<String> = [
        // Sonarr / Radarr / Lidarr / Whisparr — lookups and library listings
        "sonarr_search",
        "sonarr_get_series",
        "radarr_search",
        "radarr_get_movies",
        "lidarr_search",
        "lidarr_get_artists",
        "lidarr_get_artist_albums",
        "whisparr_search",
        "whisparr_get_movies",
        // TMDB — pure metadata API calls, no arr state involved
        "tmdb_search_person",
        "tmdb_discover_movies",
        "tmdb_discover_series",
        // Cross-cutting: suggestions, calendar, diagnostics, queue
        "suggest_titles",
        "check_titles",
        "discover_in_quiz",
        "get_calendar",
        "health",
        "get_title_details",
        "custom_formats",
        "list_download_queue",
        // `media_server_scan_library` is not here: it queues work on the user's server.
        "media_server_watch_history",
        "media_server_now_playing",
    ]

    /// Fail-closed: an unrecognised name counts as destructive.
    public static func isDestructive(_ name: String) -> Bool {
        !readOnlyTools.contains(name)
    }
}
