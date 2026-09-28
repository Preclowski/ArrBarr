import Foundation

/// Canonical tool names, descriptions and input schemas, read by both
/// LocalToolBackend and ChatViewModelFactory.
nonisolated public enum ChatToolCatalog {

    /// Gated on what's configured so the LLM doesn't call services that would just error.
    public static func tools(
        includeSonarr: Bool = true,
        includeRadarr: Bool = true,
        includeLidarr: Bool = false,
        includeWhisparr: Bool = false,
        includeTMDBMovies: Bool = false,
        includeTMDBSeries: Bool = false,
        includeMediaServer: Bool = false
    ) -> [MCPTool] {
        var arr: [MCPTool] = []
        if includeSonarr { arr.append(contentsOf: sonarrTools) }
        if includeRadarr { arr.append(contentsOf: radarrTools) }
        if includeLidarr { arr.append(contentsOf: lidarrTools) }
        if includeWhisparr { arr.append(contentsOf: whisparrTools) }
        if includeTMDBMovies || includeTMDBSeries {
            arr.append(contentsOf: tmdbSharedTools)
        }
        if includeTMDBMovies { arr.append(contentsOf: tmdbMovieTools) }
        if includeTMDBSeries { arr.append(contentsOf: tmdbSeriesTools) }
        // suggest_titles resolves through Sonarr / Radarr lookups.
        if includeSonarr || includeRadarr {
            arr.append(contentsOf: suggestTools)
        }
        if includeSonarr || includeRadarr || includeLidarr || includeWhisparr {
            arr.append(contentsOf: queueTools)
        }
        if includeSonarr || includeRadarr || includeLidarr || includeWhisparr {
            arr.append(contentsOf: calendarTools)
        }
        if includeSonarr || includeRadarr || includeLidarr || includeWhisparr {
            arr.append(contentsOf: healthTools)
        }
        if includeSonarr || includeRadarr {
            arr.append(contentsOf: titleDetailsTools)
        }
        if includeSonarr || includeRadarr {
            arr.append(contentsOf: customFormatTools)
        }
        if includeMediaServer {
            arr.append(contentsOf: mediaServerTools)
        }
        return arr
    }

    public static func llmTools(
        includeSonarr: Bool = true,
        includeRadarr: Bool = true,
        includeLidarr: Bool = false,
        includeWhisparr: Bool = false,
        includeTMDBMovies: Bool = false,
        includeTMDBSeries: Bool = false,
        includeMediaServer: Bool = false
    ) -> [LLMTool] {
        tools(includeSonarr: includeSonarr, includeRadarr: includeRadarr,
              includeLidarr: includeLidarr, includeWhisparr: includeWhisparr,
              includeTMDBMovies: includeTMDBMovies, includeTMDBSeries: includeTMDBSeries,
              includeMediaServer: includeMediaServer).map {
            LLMTool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
        }
    }

    // MARK: - Tool directory (for the Settings → MCP pane)

    /// Settings-pane row; `summary` is a human one-liner, separate from the
    /// LLM-facing `MCPTool.description`.
    public struct MCPToolInfo: Identifiable {
        public let name: String
    /// Localization key resolved by the pane.
        public let summary: String
        public let services: [ServiceKind]
        /// SF Symbol for tools outside the `ServiceKind` roster (the media server
        /// has no brand mark in the icon set).
        public let systemImage: String?
        public var id: String { name }

        public init(name: String, summary: String, services: [ServiceKind],
                    systemImage: String? = nil) {
            self.name = name
            self.summary = summary
            self.services = services
            self.systemImage = systemImage
        }
    }

    /// All tools regardless of configuration: toggling here is about the MCP surface.
    public static var toolDirectory: [MCPToolInfo] {
        [
            .init(name: "sonarr_search", summary: "Search TV series to add", services: [.sonarr]),
            .init(name: "sonarr_get_series", summary: "List library series & season status", services: [.sonarr]),
            .init(name: "sonarr_monitor_season", summary: "Monitor & grab whole seasons", services: [.sonarr]),
            .init(name: "sonarr_search_episodes", summary: "Search specific episodes", services: [.sonarr]),
            .init(name: "radarr_search", summary: "Search movies to add", services: [.radarr]),
            .init(name: "radarr_get_movies", summary: "List library movies", services: [.radarr]),
            .init(name: "radarr_search_movie", summary: "Force a movie search", services: [.radarr]),
            .init(name: "lidarr_search", summary: "Search music artists to add", services: [.lidarr]),
            .init(name: "lidarr_get_artists", summary: "List library artists", services: [.lidarr]),
            .init(name: "lidarr_get_artist_albums", summary: "List an artist's albums", services: [.lidarr]),
            .init(name: "lidarr_monitor_album", summary: "Monitor & grab an album", services: [.lidarr]),
            .init(name: "lidarr_search_album", summary: "Force an album search", services: [.lidarr]),
            .init(name: "whisparr_search", summary: "Search adult scenes to add", services: [.whisparr]),
            .init(name: "whisparr_get_movies", summary: "List Whisparr library", services: [.whisparr]),
            .init(name: "tmdb_search_person", summary: "Find a person and their filmography", services: [.radarr, .sonarr]),
            .init(name: "tmdb_discover_movies", summary: "Discover movies by genre / year", services: [.radarr]),
            .init(name: "tmdb_discover_series", summary: "Discover series by genre / year", services: [.sonarr]),
            .init(name: "suggest_titles", summary: "Curated title suggestions", services: [.sonarr, .radarr]),
            .init(name: "check_titles", summary: "Check titles against your library", services: [.sonarr, .radarr]),
            .init(name: "discover_in_quiz", summary: "Open the swipe-to-pick quiz", services: [.sonarr, .radarr]),
            .init(name: "get_calendar", summary: "Upcoming releases across services", services: [.sonarr, .radarr, .lidarr, .whisparr]),
            .init(name: "health", summary: "Check service & download-client health",
                  services: [.sonarr, .radarr, .lidarr, .whisparr, .sabnzbd, .nzbget, .qbittorrent, .transmission, .rtorrent, .deluge]),
            .init(name: "get_title_details", summary: "Details & cast for one title", services: [.sonarr, .radarr]),
            .init(name: "custom_formats", summary: "Inspect custom-format scoring", services: [.sonarr, .radarr]),
            .init(name: "list_download_queue", summary: "Show the active download queue",
                  services: [.sonarr, .radarr, .lidarr, .whisparr]),
            .init(name: "media_server_watch_history", summary: "What was recently watched",
                  services: [], systemImage: "play.tv"),
            .init(name: "media_server_now_playing", summary: "What is playing right now",
                  services: [], systemImage: "play.circle"),
            .init(name: "media_server_scan_library", summary: "Ask the media server to rescan",
                  services: [], systemImage: "arrow.clockwise"),
        ]
    }

    public static var allToolNames: [String] { toolDirectory.map(\.name) }
}
