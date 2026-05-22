import Foundation

/// Canonical list of chat tools advertised to the LLM. Single source of truth
/// for tool names, descriptions and input schemas. Both LocalToolBackend (the
/// in-process implementation) and ChatViewModelFactory (which advertises the
/// tools to the LLM provider) read from here.
public enum ChatToolCatalog {

    /// Returns the catalog of tools. Pass `includeWhisparr: true` only when
    /// `ConfigStore.aiKnowsAboutWhisparr` is true — Whisparr tools are hidden
    /// by default to avoid surfacing NSFW content to the LLM.
    public static func tools(includeWhisparr: Bool = false) -> [MCPTool] {
        var arr = baseTools
        if includeWhisparr { arr.append(contentsOf: whisparrTools) }
        return arr
    }

    /// Deprecated shim for callers that haven't adopted the function form yet.
    public static var allTools: [MCPTool] { tools(includeWhisparr: false) }

    /// Convert the catalog into `LLMTool` values for provider advertisement.
    public static func llmTools(includeWhisparr: Bool = false) -> [LLMTool] {
        tools(includeWhisparr: includeWhisparr).map {
            LLMTool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
        }
    }

    private static let baseTools: [MCPTool] = [
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
        MCPTool(
            name: "lidarr_search",
            description: "Search Lidarr's metadata source (MusicBrainz) for a music artist. Returns matches with their foreignArtistId. Use BEFORE lidarr_add_artist.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Artist name to search for, e.g. 'Radiohead'"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        MCPTool(
            name: "lidarr_get_artists",
            description: "List music artists currently in the Lidarr library. Use this when the user references an artist they already follow.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional name filter — case-insensitive substring match. Omit to list all artists."),
                    ]),
                ]),
            ])
        ),
        MCPTool(
            name: "lidarr_get_calendar",
            description: "Get upcoming album releases from Lidarr (next ~30 days, items already monitored).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        MCPTool(
            name: "lidarr_add_artist",
            description: "Add a music artist to Lidarr for tracking. ALWAYS run lidarr_search first and pass the foreignArtistId (a MusicBrainz UUID) here.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "foreignArtistId": .object([
                        "type": .string("string"),
                        "description": .string("MusicBrainz id (UUID) from lidarr_search results"),
                    ]),
                    "artistName": .object([
                        "type": .string("string"),
                        "description": .string("Artist name fallback when no foreignArtistId is known"),
                    ]),
                ]),
            ])
        ),
    ]

    private static let whisparrTools: [MCPTool] = [
        MCPTool(
            name: "whisparr_search",
            description: "Search Whisparr's adult scene library (StashDB/TPDB) for a scene or performer. Returns matches with their id. Use BEFORE whisparr_add_scene.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Scene title, performer, or studio to search for"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        MCPTool(
            name: "whisparr_get_movies",
            description: "List adult scenes currently in the Whisparr library. Use when the user asks about their Whisparr collection.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional title filter — case-insensitive substring match. Omit to list all."),
                    ]),
                ]),
            ])
        ),
        MCPTool(
            name: "whisparr_get_calendar",
            description: "Get upcoming scene releases from Whisparr (next ~30 days, items already monitored).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        MCPTool(
            name: "whisparr_add_scene",
            description: "Add an adult scene to Whisparr for tracking and automatic download. ALWAYS run whisparr_search first and pass the id from the result.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "foreignId": .object([
                        "type": .string("string"),
                        "description": .string("Scene id from whisparr_search results (tmdbId as string or StashDB/TPDB id)"),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Scene title (fallback when no foreignId is known)"),
                    ]),
                ]),
            ])
        ),
    ]
}
