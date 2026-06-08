import ArrCore
import MCP

/// Maps ArrCore's `ChatToolCatalog` entries into MCP SDK `Tool` values, applying
/// `MCPToolWhitelist` to set read-only / destructive hints and filtering the
/// user's disabled-tool opt-outs.
enum ToolCatalogBridge {
    static func sdkTools(catalog: [MCPTool], disabled: Set<String>) -> [Tool] {
        catalog.filter { !disabled.contains($0.name) }.map { t in
            // MCPToolWhitelist.isDestructive now matches both the infix
            // `_action_` form and the bare trailing `_action` suffix, so the
            // old local suffix workaround is no longer needed.
            let destructive = MCPToolWhitelist.isDestructive(t.name)
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
