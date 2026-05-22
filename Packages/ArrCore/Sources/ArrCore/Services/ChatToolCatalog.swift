import Foundation

/// Canonical list of chat tools advertised to the LLM. Single source of truth
/// for tool names, descriptions and input schemas. Both LocalToolBackend (the
/// in-process implementation) and ChatViewModelFactory (which advertises the
/// tools to the LLM provider) read from here.
///
/// External MCP servers will return their own schemas via `listTools()`; we
/// don't currently fetch and use those, so the schemas in this catalog are
/// what the LLM sees regardless of which backend serves them. Tool *names*
/// are designed to match mcp-arr's, so call dispatch works either way.
public enum ChatToolCatalog {
    public static let tools: [MCPTool] = [
        MCPTool(
            name: "sonarr_search",
            description: "Search Sonarr's metadata source (TVDB) for a TV series. Returns a list of matches with their tvdbId. Use this BEFORE sonarr_add_series so the user can disambiguate and you can pass the correct tvdbId.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Series title or keyword to search for, e.g. 'Severance' or 'Severance 2022'"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        MCPTool(
            name: "radarr_search",
            description: "Search Radarr's metadata source (TMDB) for a movie. Returns a list of matches with their tmdbId. Use this BEFORE radarr_add_movie so the user can disambiguate and you can pass the correct tmdbId.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Movie title or keyword to search for, e.g. 'Severance' or 'Colony 2026'"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        MCPTool(
            name: "sonarr_get_calendar",
            description: "Get upcoming TV episode releases from Sonarr (next ~7 days, items already monitored).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        MCPTool(
            name: "radarr_get_calendar",
            description: "Get upcoming movie releases from Radarr (next ~7 days, items already monitored).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        MCPTool(
            name: "sonarr_add_series",
            description: "Add a TV series to Sonarr for tracking + automatic download. ALWAYS run sonarr_search first and pass tvdbId from the result. Title is a last-resort fallback.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "tvdbId": .object([
                        "type": .string("integer"),
                        "description": .string("TVDB id from sonarr_search results — strongly preferred"),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Series title (fallback when no tvdbId is known)"),
                    ]),
                ]),
            ])
        ),
        MCPTool(
            name: "radarr_add_movie",
            description: "Add a movie to Radarr for tracking + automatic download. ALWAYS run radarr_search first and pass tmdbId from the result. Title is a last-resort fallback.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "tmdbId": .object([
                        "type": .string("integer"),
                        "description": .string("TMDB id from radarr_search results — strongly preferred"),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Movie title (fallback when no tmdbId is known)"),
                    ]),
                ]),
            ])
        ),
        MCPTool(
            name: "sonarr_get_series",
            description: "List TV series currently in the Sonarr library (already added by the user). Use this when the user references a show they already have — to look it up, check its status, or get its tvdbId. Different from sonarr_search, which queries TVDB to find NEW series to add.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional title filter — case-insensitive substring match. Omit to list all series."),
                    ]),
                ]),
            ])
        ),
        MCPTool(
            name: "radarr_get_movies",
            description: "List movies currently in the Radarr library (already added by the user). Use this when the user references a movie they already have — to look it up, check status, or get its tmdbId. Different from radarr_search, which queries TMDB to find NEW movies to add.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional title filter — case-insensitive substring match. Omit to list all movies."),
                    ]),
                ]),
            ])
        ),
    ]

    /// Convert the catalog into `LLMTool` values for provider advertisement.
    public static var llmTools: [LLMTool] {
        tools.map { LLMTool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) }
    }
}
