import ArrCore
import MCP
import MediaKit

/// Applies `MCPToolWhitelist` hints and drops the user's disabled tools.
enum ToolCatalogBridge {
    static func sdkTools(catalog: [ToolDefinition], disabled: Set<String>) -> [Tool] {
        catalog.filter { !disabled.contains($0.name) }.map { t in
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
