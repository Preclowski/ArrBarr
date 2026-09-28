import Foundation

nonisolated extension ChatToolCatalog {

    // MARK: - Unified calendar (all arrs)

    static let calendarTools: [MCPTool] = [
        MCPTool(
            name: "get_calendar",
            description: """
            Upcoming releases from every configured arr in one list — TV episodes (Sonarr), movies (Radarr), albums (Lidarr), scenes (Whisparr) — already-monitored items, sorted by air date. Surfaces as calendar cards in the chat.

            USE THIS for "what's coming up?", "what's releasing this week?", "anything new soon?". Pass the optional `service` to narrow to one arr (e.g. service='sonarr' for just upcoming episodes); omit it to see everything across all configured services.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "service": .object([
                        "type": .string("string"),
                        "enum": .array([.string("sonarr"), .string("radarr"), .string("lidarr"), .string("whisparr")]),
                        "description": .string("Optional. Narrow to one arr: 'sonarr' (episodes), 'radarr' (movies), 'lidarr' (albums), 'whisparr' (scenes). Omit to merge all configured services."),
                    ]),
                ]),
            ])
        ),
    ]

    // MARK: - Cross-arr status / diagnostics

    static let healthTools: [MCPTool] = [
        MCPTool(
            name: "health",
            description: """
            Whole-stack health check: every configured arr (Sonarr, Radarr, Lidarr, Whisparr) AND every configured download client (qBittorrent, Transmission, NZBGet, SABnzbd, rTorrent, Deluge). For arrs it returns the bell-icon warnings + errors (disconnected indexers, missing root folders, full disk, stuck queue). For download clients it reports whether ArrBarr can actually reach and authenticate with each one.

            USE THIS for "is everything working", "what's the state of my setup", "are there any issues", "any problems with Sonarr / qBittorrent", "is my download client connected". DO NOT use `sonarr_get_series` / `radarr_get_movies` for status questions — those list library contents and say nothing about health.

            Output is plain text (no cards). Relay the per-service summary briefly. Inline the most actionable warnings if any.
            """,
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
    ]
}
