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
        // Search tools — query indexers, often start a grab. The single-
        // episode case fires *N* indexer queries when the season's
        // monitor toggle hits the cascade-then-search path.
        if name.contains("_search_") { return true }

        // Monitor tools — flip monitored state and (in our impls) fire
        // an immediate SeasonSearch / AlbumSearch when state=true.
        // We gate regardless of the args' `state` value to keep the
        // check simple at this layer; the confirm card surfaces the
        // raw arguments so the user sees what's about to happen.
        if name.contains("_monitor_") { return true }

        // Add tools — none ship today (tap-the-card is the canonical
        // add UX). Future-proof gate in case anything brings them back.
        if name.contains("_add_") { return true }

        // Delete / remove — same reasoning.
        if name.contains("_delete_") || name.contains("_remove_") { return true }

        return false
    }
}
