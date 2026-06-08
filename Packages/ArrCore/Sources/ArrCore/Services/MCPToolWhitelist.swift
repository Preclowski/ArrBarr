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
        // Action words that gate. We match each both as an infix segment
        // (`sonarr_search_episodes`) and as a bare trailing suffix
        // (`sonarr_search`) — catalog tools like `sonarr_search` /
        // `radarr_search` put the action last with no following segment,
        // so an infix-only check would let them slip through un-gated.
        for action in ["search", "monitor", "add", "delete", "remove"] {
            // Search tools query indexers and often start a grab; monitor
            // tools flip monitored state and fire an immediate
            // SeasonSearch / AlbumSearch when state=true; add/delete/remove
            // mutate arr state. We gate regardless of arg values to keep
            // the check simple — the confirm card surfaces the raw
            // arguments so the user sees exactly what's about to happen.
            if name.contains("_\(action)_") || name.hasSuffix("_\(action)") {
                return true
            }
        }

        return false
    }
}
