import Foundation

/// Destructive-action gating for chat tools. When the LLM picks a tool
/// whose name matches one of these patterns, the chat pipeline pauses
/// and surfaces a ConfirmActionCard — the user has to explicitly tap
/// Confirm before the tool actually runs. Cancel returns the call as
/// "cancelled by user" so the model can adjust its plan.
///
/// We previously stripped this whole module out (every shipping tool
/// became read-only after `*_add_*` got dropped). It came back when we
/// added `*_search_*` and `*_monitor_*` tools — both queue indexer
/// traffic and can trigger downloads, so the user wants veto power
/// before the LLM lobs one on its own.
public enum MCPToolWhitelist {

    /// True when the named tool can trigger downloads / indexer traffic
    /// / arr state mutations. Pattern-based so we don't have to keep
    /// this list and the tool catalog in lockstep; new tools picking
    /// up these conventions are gated automatically.
    public static func isDestructive(_ name: String) -> Bool {
        // Indexer searches grab releases — but ONLY the infix form on an *arr
        // tool (`sonarr_search_episodes`, `radarr_search_movie`,
        // `lidarr_search_album`). The bare `<arr>_search` tools are metadata
        // LOOKUPS that surface add candidates (the user taps a card to add); they
        // query no indexer and start no grab, so they are read-only and NOT gated.
        // Scope the `_search_` rule to the arr prefixes so read-only lookups like
        // `tmdb_search_person` (a pure TMDB API call) are not falsely gated.
        let indexerArrs = ["sonarr", "radarr", "lidarr", "whisparr"]
        if indexerArrs.contains(where: { name.hasPrefix($0) }), name.contains("_search_") {
            return true
        }

        // Monitor / add / delete / remove mutate arr state wherever the action
        // word sits (monitor fires an immediate SeasonSearch/AlbumSearch when
        // state=true). Gate both the infix (`_action_`) and the bare trailing
        // suffix (`_action`) so a future bare `sonarr_delete` is caught too.
        for action in ["monitor", "add", "delete", "remove"] {
            if name.contains("_\(action)_") || name.hasSuffix("_\(action)") {
                return true
            }
        }

        return false
    }
}
