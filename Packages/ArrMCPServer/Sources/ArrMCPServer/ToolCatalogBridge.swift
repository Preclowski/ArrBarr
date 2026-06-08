import ArrCore
import MCP

/// Maps ArrCore's `ChatToolCatalog` entries into MCP SDK `Tool` values, applying
/// `MCPToolWhitelist` to set read-only / destructive hints and filtering the
/// user's disabled-tool opt-outs.
enum ToolCatalogBridge {
    /// Action words that mean "mutates / kicks off a grab" when they appear as
    /// the bare trailing segment of a tool name (e.g. `sonarr_search`).
    /// `MCPToolWhitelist.isDestructive` only matches the infix `_action_` form
    /// (e.g. `sonarr_search_episodes`); this catches the suffix case it misses.
    private static let destructiveSuffixes = ["_search", "_monitor", "_add", "_delete", "_remove"]

    static func isDestructive(_ name: String) -> Bool {
        if MCPToolWhitelist.isDestructive(name) { return true }
        return destructiveSuffixes.contains { name.hasSuffix($0) }
    }

    static func sdkTools(catalog: [MCPTool], disabled: Set<String>) -> [Tool] {
        catalog.filter { !disabled.contains($0.name) }.map { t in
            let destructive = isDestructive(t.name)
            return Tool(
                name: t.name,
                description: t.description,
                inputSchema: JSONValueBridge.toMCP(t.inputSchema),
                annotations: Tool.Annotations(
                    readOnlyHint: !destructive,
                    destructiveHint: destructive,
                    openWorldHint: t.name.contains("_search") || t.name.hasPrefix("tmdb_")
                )
            )
        }
    }
}
