import Foundation

nonisolated extension ChatToolCatalog {

    // MARK: - Media server (Plex / Jellyfin / Emby)

    static let mediaServerTools: [MCPTool] = [
        MCPTool(
            name: "media_server_watch_history",
            description: """
            What the user has recently FINISHED watching on their media server (Plex / Jellyfin / Emby), newest first. Returns title, year and when it was watched; episodes are reported as their series.

            USE THIS for the recent stream itself — "what have I watched lately", "what did I finish this week", "recommend something based on what I've been watching". The arrs know what was downloaded, never what was played.

            DO NOT use this to answer "have I seen X" for a NAMED title: this is only the most recent plays, so a film watched last year isn't in it and you would wrongly conclude they haven't seen it. That question is `check_titles`, which reads watch state for the whole library. Nor is this a library listing (`radarr_get_movies` / `sonarr_get_series`) or what is on screen right now (`media_server_now_playing`).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("How many recent plays to return. Defaults to 20, capped at 100."),
                    ]),
                ]),
            ])
        ),
        MCPTool(
            name: "media_server_now_playing",
            description: """
            Active playback sessions on the media server right now: what is playing, which user, on which device, and whether the server is transcoding or direct-playing.

            USE THIS for "is anyone watching", "what's playing", "who's using the server", "is it transcoding". Returns an empty list when nothing is playing — say so plainly rather than guessing.
            """,
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        MCPTool(
            name: "media_server_scan_library",
            description: """
            Ask the media server to rescan its libraries, so a title an arr just imported shows up without waiting for the server's own schedule.

            USE THIS after an import the user is waiting on ("it finished downloading but it's not in Plex"). This queues work on the server and needs the user's confirmation; the result reports only that the request was accepted, not that the scan has finished.
            """,
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
    ]
}
