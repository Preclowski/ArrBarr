import Foundation

/// Destructive-action gating for the tool catalog. A tool that is not on the
/// read-only allowlist below cannot run until a human says yes: the chat
/// pauses and surfaces a ConfirmActionCard, the MCP server raises an
/// elicitation. Cancel comes back as "cancelled by user" so the model can
/// adjust its plan.
///
/// We previously stripped this whole module out (every shipping tool
/// became read-only after `*_add_*` got dropped). It came back when we
/// added `*_search_*` and `*_monitor_*` tools — both queue indexer
/// traffic and can trigger downloads, so the user wants veto power
/// before the LLM lobs one on its own.
///
/// The rule used to be a DENYLIST of name patterns (`_add_`, `_monitor_`,
/// `<arr>*_search_*`, …). It covered every tool we ship, but only by luck of
/// naming: it was fail-OPEN by construction, so a future `queue_purge` or
/// `sonarr_blocklist_release` would have matched nothing and run unconfirmed.
/// It is now an ALLOWLIST — anything not listed needs confirmation, so a newly
/// added tool stays gated until somebody deliberately vouches for it.
public enum MCPToolWhitelist {

    /// Every tool that only READS: metadata lookups, library listings,
    /// calendar / queue / health reporting, TMDB queries, and the two
    /// suggestion tools (they resolve titles for display and seed the Quiz
    /// overlay — neither adds anything; the user still swipes or taps).
    ///
    /// Spelled out name by name on purpose: growing the catalog must not
    /// silently widen what an unattended MCP client is allowed to run. Keep in
    /// sync with `ChatToolCatalog.toolDirectory` — a stale name left here is
    /// harmless, a mutating name added here is not.
    ///
    /// NOT listed, i.e. gated: `sonarr_monitor_season` / `lidarr_monitor_album`
    /// (flip monitoring AND fire an immediate season/album search) and
    /// `sonarr_search_episodes` / `radarr_search_movie` / `lidarr_search_album`
    /// (manual indexer searches — they grab releases). Note the bare
    /// `<arr>_search` tools ARE read-only: they are metadata lookups that
    /// surface add candidates as cards, hit no indexer and start no grab.
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
        // Media server — both are plain reads of play state.
        // `media_server_scan_library` is NOT here: it queues work on someone's
        // server, which is exactly the class of thing the user wants to approve.
        "media_server_watch_history",
        "media_server_now_playing",
    ]

    /// True when the named tool needs an explicit user confirmation before it
    /// runs — i.e. it can trigger downloads / indexer traffic / arr state
    /// mutations. Fail-closed: a name we don't recognise counts as
    /// destructive, because "unknown" is exactly the case we got wrong before.
    public static func isDestructive(_ name: String) -> Bool {
        !readOnlyTools.contains(name)
    }
}
