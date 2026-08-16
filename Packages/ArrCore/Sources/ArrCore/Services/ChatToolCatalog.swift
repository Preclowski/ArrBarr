import Foundation

/// Canonical list of chat tools advertised to the LLM. Single source of truth
/// for tool names, descriptions and input schemas. Both LocalToolBackend (the
/// in-process implementation) and ChatViewModelFactory (which advertises the
/// tools to the LLM provider) read from here.
public enum ChatToolCatalog {

    /// Returns the catalog gated on what's actually configured. Each `include*`
    /// flag should mirror `ConfigStore.<arr>.isConfigured` (and
    /// `tmdbEnabled && <arr>.isConfigured` for the TMDB tools) so the LLM
    /// doesn't see and call into services that would just error out.
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
        // suggest_titles resolves through Sonarr / Radarr lookups, so it
        // only makes sense when at least one of those arrs is configured.
        if includeSonarr || includeRadarr {
            arr.append(contentsOf: suggestTools)
        }
        // list_download_queue spans Sonarr + Radarr; expose it whenever
        // either is configured.
        if includeSonarr || includeRadarr {
            arr.append(contentsOf: queueTools)
        }
        // Unified calendar spans every configured arr; expose it whenever
        // at least one is configured (the tool's optional `service` arg
        // narrows it).
        if includeSonarr || includeRadarr || includeLidarr || includeWhisparr {
            arr.append(contentsOf: calendarTools)
        }
        // `health` checks arrs AND download clients; surface whenever any
        // arr is configured (download clients ride along inside).
        if includeSonarr || includeRadarr || includeLidarr || includeWhisparr {
            arr.append(contentsOf: healthTools)
        }
        // Single-title detail lookup (overview + optional cast) for movies /
        // series.
        if includeSonarr || includeRadarr {
            arr.append(contentsOf: titleDetailsTools)
        }
        // Custom-format tool targets Sonarr / Radarr (both v3 customformat API).
        if includeSonarr || includeRadarr {
            arr.append(contentsOf: customFormatTools)
        }
        // Media-server tools stand alone: they read Plex / Jellyfin / Emby and
        // touch no arr, so they are gated only on that connection existing.
        if includeMediaServer {
            arr.append(contentsOf: mediaServerTools)
        }
        return arr
    }

    /// Convert the catalog into `LLMTool` values for provider advertisement.
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

    /// One tool as presented in the MCP settings pane: its wire name, a short
    /// human helper line, and the apps it touches (drives the row of brand
    /// icons). Separate from the LLM-facing `MCPTool.description` (which is a
    /// long prompt-engineered blurb) — this `summary` is a one-liner for a
    /// human skimming the list.
    public struct MCPToolInfo: Identifiable {
        public let name: String
        /// Short helper line (a localization key resolved by the pane).
        public let summary: String
        /// Apps the tool drives — rendered as a row of brand icons.
        public let services: [ServiceKind]
        /// SF Symbol shown instead of brand icons. Set for tools that drive
        /// something outside the `ServiceKind` roster — the media server has
        /// no brand mark in the icon set, and inventing one per server would
        /// mean three more assets for a row of a settings list.
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

    /// Flat directory of every catalog tool, in catalog order. The pane shows
    /// all of them regardless of what's configured — toggling a tool here is
    /// about the MCP surface, independent of whether that arr is set up.
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
            .init(name: "list_download_queue", summary: "Show the active download queue", services: [.sonarr, .radarr]),
            .init(name: "media_server_watch_history", summary: "What was recently watched",
                  services: [], systemImage: "play.tv"),
            .init(name: "media_server_now_playing", summary: "What is playing right now",
                  services: [], systemImage: "play.circle"),
            .init(name: "media_server_scan_library", summary: "Ask the media server to rescan",
                  services: [], systemImage: "arrow.clockwise"),
        ]
    }

    /// Flat list of every tool name — used to compute "all enabled" defaults
    /// and the on/off summary count in the MCP pane.
    public static var allToolNames: [String] { toolDirectory.map(\.name) }

    // MARK: - Sonarr

    private static let sonarrTools: [MCPTool] = [
        MCPTool(
            name: "sonarr_search",
            description: "Search Sonarr's metadata source (TVDB) for a TV series. Results surface in the chat as tappable cards — the user opens each one and confirms profile / folder / quality in the SearchAddPanel to actually add it. You do NOT add anything yourself; there is no `sonarr_add_*` tool. Briefly explain WHY this set after the call.",
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
            name: "sonarr_get_series",
            description: """
            The user's OWN series library — each row carries `seriesId`, genres, rating, per-season monitor state with have/total episode counts (`S1 ✓ 10/10, S2 ✗ 0/10`) and, with a media server connected, whether it was watched. Same genre / startYear / endYear arguments as `tmdb_discover_series`, pointed at their shelf.

            USE for 'do I have season N monitored?', 'which seasons of X am I tracking?', 'find seriesId for X', 'what unwatched shows do I have'. The seriesId here is what `sonarr_monitor_season` and `sonarr_search_episodes` expect. `seasonNumber` zooms the strip to one season.

            NOT for titles you can already name — that is `check_titles`, one call for a whole list. Use this one to explore the shelf by filter, or when you need a `seriesId` or the season strip for a show the user just named. A call with no arguments returns a random sample, labelled as such: flavour, not reconnaissance.

            Title matching tolerates accents, articles and typos. Person queries are tmdb_*; service health is `health`.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional title. Accent-, article- and typo-tolerant."),
                    ]),
                    "genre": .object([
                        "type": .string("string"),
                        "description": .string("Optional genre name, same vocabulary as tmdb_discover_series (drama, comedy, crime, sci-fi & fantasy, …)."),
                    ]),
                    "startYear": .object([
                        "type": .string("integer"),
                        "description": .string("Inclusive lower bound on first-air year."),
                    ]),
                    "endYear": .object([
                        "type": .string("integer"),
                        "description": .string("Inclusive upper bound on first-air year."),
                    ]),
                    "unwatched": .object([
                        "type": .string("boolean"),
                        "description": .string("Only series the media server says are unwatched. Needs a connected media server; ignored (and said so) without one."),
                    ]),
                    "seasonNumber": .object([
                        "type": .string("integer"),
                        "description": .string("Optional. When set, the per-season strip is filtered to just this season (e.g. 3 → 'S3 ✓ 5/10'). Lets you answer 'is S3 of X monitored?' in one call."),
                    ]),
                ]),
            ])
        ),
        MCPTool(
            name: "sonarr_monitor_season",
            description: "Flip monitoring on one or MORE whole seasons in a single call. When state=true, ALSO fires a SeasonSearch for each season automatically — there is no opt-out, because chat requests like 'pobierz mi 3 sezon' / 'monitor S3' always mean 'and grab it'. When state=false, no search runs. Pass EVERY season the user named in seasonNumbers — 'pobierz 10 i 11 sezon' → seasonNumbers:[10,11]; do NOT make a separate call per season. The result text REPORTS THE ACTUAL OUTCOME ('OK', 'PARTIAL', or 'FAILED') and lists exactly which seasons worked; relay that to the user faithfully — do not claim success if the result says PARTIAL or FAILED.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "seriesId": .object([
                        "type": .string("integer"),
                        "description": .string("Sonarr series id. Get via sonarr_get_series."),
                    ]),
                    "seasonNumbers": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "description": .string("One or more season numbers (1-based, ignore season 0 specials). Include EVERY season the user requested in this one array, e.g. [10, 11] for 'sezon 10 i 11'."),
                    ]),
                    "state": .object([
                        "type": .string("boolean"),
                        "description": .string("true = monitor + search, false = unmonitor (no search). Defaults to true."),
                    ]),
                ]),
                "required": .array([.string("seriesId"), .string("seasonNumbers")]),
            ])
        ),
        MCPTool(
            name: "sonarr_search_episodes",
            description: "Manual indexer search for one or more specific episodes by id. USE for 'search S3E5 of X', 'try again to grab this episode', 'retry the missing finale'. For whole-season grabs use sonarr_monitor_season with alsoSearch=true. The user sees results in the queue when indexers report back.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "episodeIds": .object([
                        "type": .string("array"),
                        "description": .string("Array of Sonarr episode ids. The chat doesn't always have these — usually used after a missing-episodes flow or after the user pasted them. For 'season X' use sonarr_monitor_season(state:true, alsoSearch:true)."),
                        "items": .object(["type": .string("integer")]),
                    ]),
                ]),
                "required": .array([.string("episodeIds")]),
            ])
        ),
    ]

    // MARK: - Radarr

    private static let radarrTools: [MCPTool] = [
        MCPTool(
            name: "radarr_search",
            description: "Search Radarr's metadata source (TMDB) for a movie. Results surface in the chat as tappable cards — the user opens each one and confirms profile / folder / quality in the SearchAddPanel to actually add it. You do NOT add anything yourself; there is no `radarr_add_*` tool. Briefly explain WHY this set after the call.",
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
            name: "radarr_get_movies",
            description: """
            The user's OWN movie library. Same lens as `tmdb_discover_movies` (identical genre / startYear / endYear arguments) pointed at their shelf instead of at the world — use it whenever the question is "what do I have", "what can I watch tonight", "what unwatched sci-fi is on my shelf".

            Every row carries genres, rating, whether the file is downloaded and (with a media server connected) whether it was watched — so YOU apply the taste judgement. "Romantic but not a drama" is your call from the rows, not a filter: half the great romances are tagged Drama.

            NOT for titles you can already name — that is `check_titles`, which answers a whole list in one call. Use this one when you do NOT have the titles yet and are exploring the shelf by filter. A call with no arguments returns a random sample, labelled as such: it is flavour, not reconnaissance, and it proves nothing about whether any particular film is owned. If your next move would be `check_titles`, skip this call entirely and go straight there.

            Title matching tolerates accents, articles and typos. For cast / crew queries use tmdb_search_person, with `credits` set when the ask is what they made (the library has no crew data). For service health use `health`.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional title. Accent-, article- and typo-tolerant."),
                    ]),
                    "genre": .object([
                        "type": .string("string"),
                        "description": .string("Optional genre name, same vocabulary as tmdb_discover_movies (action, comedy, romance, horror, science fiction, …)."),
                    ]),
                    "startYear": .object([
                        "type": .string("integer"),
                        "description": .string("Inclusive lower bound on release year (1990 for '90s films')."),
                    ]),
                    "endYear": .object([
                        "type": .string("integer"),
                        "description": .string("Inclusive upper bound on release year (1999 for '90s films')."),
                    ]),
                    "unwatched": .object([
                        "type": .string("boolean"),
                        "description": .string("Only titles the media server says are unwatched. Needs a connected media server; ignored (and said so) without one."),
                    ]),
                ]),
            ])
        ),
        MCPTool(
            name: "radarr_search_movie",
            description: "Force an indexer search for one movie. USE for 'this didn't download, try again', 'spróbuj ściągnąć ponownie', 'try to grab a better quality of X'. Monitoring isn't changed — if you also need to flip monitor on, just add the movie via the UI card flow first. Returns confirmation text; results land in the queue when indexers respond.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "movieId": .object([
                        "type": .string("integer"),
                        "description": .string("Radarr movie id. Get via radarr_get_movies, or from tmdb_search_person with credits (its cross-reference fills it in for owned movies)."),
                    ]),
                ]),
                "required": .array([.string("movieId")]),
            ])
        ),
    ]

    // MARK: - Lidarr

    private static let lidarrTools: [MCPTool] = [
        MCPTool(
            name: "lidarr_search",
            description: "Search Lidarr's metadata source (MusicBrainz) for a music artist. Results surface in the chat as tappable cards — the user taps to open SearchAddPanel and confirms profile/folder to add. You do NOT add anything yourself; there is no `lidarr_add_*` tool.",
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
            description: "The user's music library. FIRST CHOICE for any question about a musician, band or album — a musician is NOT a tmdb_search_person query, that tool only knows film work. Each row carries `artistId`, which is what lidarr_get_artist_albums needs; there is no other way to get it, so never invent one. `query` filters by name — pass it, an unfiltered list of a whole library is noise.",
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
            name: "lidarr_get_artist_albums",
            description: "List albums for one artist (resolved via lidarr_get_artists). Each entry carries `albumId`, title, type (Album / Single / EP / Live / Compilation / Soundtrack / Other), year, monitor state, and track-file progress. USE for 'which albums of X am I tracking?', 'what's new from X?', 'find albumId for Y'. Output is capped at 40 entries — pass `albumType` (e.g. 'Album') to narrow to studio LPs when an artist has dozens of live/compilation entries cluttering things.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "artistId": .object([
                        "type": .string("integer"),
                        "description": .string("Lidarr artist id, copied from an `artistId=` field in lidarr_get_artists output. Never a guess — a wrong id silently returns somebody else's albums."),
                    ]),
                    "albumType": .object([
                        "type": .string("string"),
                        "description": .string("Optional filter: 'Album' (studio LPs), 'Single', 'EP', 'Live', 'Compilation', 'Soundtrack', 'Other'. Case-insensitive."),
                    ]),
                ]),
                "required": .array([.string("artistId")]),
            ])
        ),
        MCPTool(
            name: "lidarr_monitor_album",
            description: "Flip monitoring on a single album. When state=true, ALSO fires an AlbumSearch automatically — no opt-out (same reasoning as sonarr_monitor_season). When state=false, no search. The result text REPORTS THE ACTUAL OUTCOME ('OK', 'PARTIAL', or 'FAILED'); relay it faithfully.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "albumId": .object([
                        "type": .string("integer"),
                        "description": .string("Lidarr album id from lidarr_get_artist_albums."),
                    ]),
                    "state": .object([
                        "type": .string("boolean"),
                        "description": .string("true = monitor + search, false = unmonitor (no search). Defaults to true."),
                    ]),
                ]),
                "required": .array([.string("albumId")]),
            ])
        ),
        MCPTool(
            name: "lidarr_search_album",
            description: "Force an AlbumSearch for one album without changing monitoring. USE for 'try again to grab X', 'spróbuj jeszcze raz pobrać Y'. For the 'monitor + grab' combo use lidarr_monitor_album(state:true, alsoSearch:true) instead.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "albumId": .object([
                        "type": .string("integer"),
                        "description": .string("Lidarr album id."),
                    ]),
                ]),
                "required": .array([.string("albumId")]),
            ])
        ),
    ]

    // MARK: - Whisparr

    private static let whisparrTools: [MCPTool] = [
        MCPTool(
            name: "whisparr_search",
            description: "Search Whisparr's adult scene library (StashDB/TPDB) for a scene or performer. Results surface in the chat as tappable cards — the user taps to open SearchAddPanel and confirms profile/folder to add. You do NOT add anything yourself; there is no `whisparr_add_*` tool.",
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
    ]

    // MARK: - TMDB shared (person lookup feeds both movie + tv credits)

    private static let tmdbSharedTools: [MCPTool] = [
        MCPTool(
            name: "tmdb_search_person",
            description: "THE tool for people in FILM and TV — actors, directors, writers. One call does the lot: it resolves a name to a TMDB personId and, with `credits` set, returns that person's filmography in the same response. Hold a personId already (ambiguous earlier search, or a name from a cast list)? Pass `personId` + `credits` instead of `query`. NOT for MUSIC: a musician or band is Lidarr's world — use lidarr_get_artists / lidarr_search, which is where albums live; this tool only knows their acting roles, if any. NEVER use radarr_get_movies or sonarr_get_series for person queries — those library tools carry no cast/crew metadata. Never guess a personId.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Person's name, e.g. 'Adam Sandler' or 'Greta Gerwig'"),
                    ]),
                    "personId": .object([
                        "type": .string("integer"),
                        "description": .string("Skip the name search — you already hold a TMDB personId (from an earlier ambiguous search, or from a cast list). Requires `credits`. `query` is ignored."),
                    ]),
                    "credits": .object([
                        "type": .string("string"),
                        "enum": .array([.string("movies"), .string("series")]),
                        "description": .string("Set when the question is about what the person made: 'movies' or 'series' returns their filmography directly. One kind per call — ask twice for both. Omit when you only need to identify the person. If the name doesn't resolve to one obvious person you get the candidate list instead — then call again with `personId` + `credits` for whichever one the user meant."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
    ]

    // MARK: - TMDB movies (gated on tmdbEnabled && Radarr configured)

    private static let tmdbMovieTools: [MCPTool] = [
        MCPTool(
            name: "tmdb_discover_movies",
            description: "Discover movies by genre and/or year range — the WORLD, not the user's shelf. Use this for 'suggest a horror for tonight', 'films from the 90s', 'best sci-fi from the last 5 years'. `radarr_get_movies` takes the same genre / startYear / endYear arguments and answers the same question about the library they already own; reach for that one when the ask is 'what do I have'. Results are marked OWNED (and WATCHED where known) and include tmdbId so taps add to Radarr. Sorted by popularity by default.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "genre": .object([
                        "type": .string("string"),
                        "description": .string("Genre name (case-insensitive). Known values: action, adventure, animation, comedy, crime, documentary, drama, family, fantasy, history, horror, music, mystery, romance, science fiction, thriller, war, western."),
                    ]),
                    "startYear": .object([
                        "type": .string("integer"),
                        "description": .string("Inclusive lower bound on release year (e.g. 1990 for '90s films')."),
                    ]),
                    "endYear": .object([
                        "type": .string("integer"),
                        "description": .string("Inclusive upper bound on release year (e.g. 1999 for '90s films')."),
                    ]),
                    "sortBy": .object([
                        "type": .string("string"),
                        "description": .string("Optional TMDB sort key. Defaults to 'popularity.desc'. Other useful values: 'vote_average.desc', 'primary_release_date.desc'."),
                    ]),
                ]),
            ])
        ),
    ]

    // MARK: - TMDB series (gated on tmdbEnabled && Sonarr configured)

    private static let tmdbSeriesTools: [MCPTool] = [
        MCPTool(
            name: "tmdb_discover_series",
            description: "Discover TV series by genre and/or year range — the WORLD, not the user's shelf. Use this for 'suggest a sci-fi series from the 2010s' or 'best comedy shows of the last 3 years'. `sonarr_get_series` takes the same genre / startYear / endYear arguments for the library they already own. Rows the user already owns are marked OWNED — matched on title + year, since TMDB tv ids are not TVDB ids, so a remake sharing a title could in principle be mismarked; `check_titles` is the exact answer when it matters. Sorted by popularity by default.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "genre": .object([
                        "type": .string("string"),
                        "description": .string("Genre name (case-insensitive). Known values: action, adventure, animation, comedy, crime, documentary, drama, family, kids, mystery, news, reality, sci-fi & fantasy, soap, talk, war & politics, western."),
                    ]),
                    "startYear": .object([
                        "type": .string("integer"),
                        "description": .string("Inclusive lower bound on first-air-date year."),
                    ]),
                    "endYear": .object([
                        "type": .string("integer"),
                        "description": .string("Inclusive upper bound on first-air-date year."),
                    ]),
                    "sortBy": .object([
                        "type": .string("string"),
                        "description": .string("Optional TMDB sort key. Defaults to 'popularity.desc'. Other useful values: 'vote_average.desc', 'first_air_date.desc'."),
                    ]),
                ]),
            ])
        ),
    ]

    // MARK: - Curated suggestions (model-knowledge picks → rich cards)
    //
    // `suggest_titles` is the right answer for taste-based queries — "in
    // the style of", "similar to", "in the mood for". The model picks
    // titles from its own training-data associations (typically better
    // than TMDB's algorithmic discover for these queries) and the tool
    // resolves each through the Sonarr/Radarr lookup so the chat shows
    // real, tappable cards with posters, ratings, and in-library state.

    private static let suggestTools: [MCPTool] = [
        MCPTool(
            name: "check_titles",
            description: """
            Ask the library about titles you already have in hand: which ones the user owns, whether the file is there, and (with a media server connected) whether they have watched it.

            USE THIS whenever you have named titles and the answer depends on the user's shelf — "have I seen any of these", "which of Villeneuve's films do I have", "is X already downloaded", or before recommending anything from your own knowledge so you don't offer what they own and watched last month. ONE call for the whole list: twenty titles in one call, never twenty separate lookups, and never a browse of the library first — a sample of the shelf cannot tell you about a title that isn't in the sample.

            This is the tool for named titles; `radarr_get_movies` / `sonarr_get_series` are for exploring the shelf by filter when you have no titles yet, and `sonarr_get_series` is still the place to get a `seriesId` with per-season detail.

            Do NOT re-check results that already arrived marked: `tmdb_search_person` (with credits), `tmdb_discover_movies` and `suggest_titles` cross-reference the library themselves and print [OWNED] / [WATCHED]. Use this for titles that came out of your own head, and whenever an exact answer matters for series — the TMDB series tools match ownership on title + year rather than on ids.

            Titles may be plain strings ("Dune 2021") or {title, year} objects; a year disambiguates remakes. Matching tolerates accents, leading articles and typos. Movies and series both — the tool works out which is which. Max 50 per call.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "titles": .object([
                        "type": .string("array"),
                        "description": .string("Titles to check, e.g. [\"Chungking Express 1994\", {\"title\": \"Severance\"}]."),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("titles")]),
            ])
        ),
        MCPTool(
            name: "suggest_titles",
            description: """
            Present a curated list of titles you (the model) recommend from your own knowledge, rendered as interactive cards with posters / ratings / in-library state.

            USE THIS for taste-based queries: "suggest a show like Mr. Robot", "movies in the style of Wes Anderson", "something in the mood for noir tonight", "good follow-up to Breaking Bad". Your training-data associations are better than `tmdb_discover_*`'s algorithmic filters for these.

            DO NOT use `tmdb_discover_*` for taste queries — those are for genre/year filters ("popular 90s horror", "highly-rated documentaries 2023") where the user picks the dimension and you do not need to curate.

            Pass 5–12 picks for a normal ask, up to 40 when you are hunting for what they DON'T have (a deep library owns most of any canonical list). Set `exclude_owned: true` for that hunt and the owned ones are dropped here — you get only the gaps, in one call. Include `year` whenever you're confident — it disambiguates remakes and same-titled works. All picks must share one `kind` per call (all series, or all movies). The tool will resolve each through Sonarr/Radarr; any pick that can't be found is silently dropped from the cards (and reported back to you) so the user only sees real, addable items.

            After the call, briefly explain WHY this set (one or two sentences max) — the cards speak for themselves visually.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object([
                        "type": .string("string"),
                        "description": .string("'series' to resolve picks through Sonarr, 'movie' through Radarr. All items in one call must share a kind."),
                    ]),
                    "items": .object([
                        "type": .string("array"),
                        "description": .string("Ordered list of picks; order is preserved in the surfaced cards."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "title": .object([
                                    "type": .string("string"),
                                    "description": .string("The work's title, e.g. 'The Wire'. Use the original-language title if that's how the metadata source indexes it."),
                                ]),
                                "year": .object([
                                    "type": .string("integer"),
                                    "description": .string("Optional release year — disambiguates remakes (Dune 1984 vs 2021). Omit when unsure."),
                                ]),
                            ]),
                            "required": .array([.string("title")]),
                        ]),
                    ]),
                    "exclude_owned": .object([
                        "type": .string("boolean"),
                        "description": .string("Drop picks the user already owns instead of marking them. Use when the ask is for things they DON'T have; the reply reports how many were dropped."),
                    ]),
                ]),
                "required": .array([.string("kind"), .string("items")]),
            ])
        ),
        MCPTool(
            name: "discover_in_quiz",
            description: """
            Open the Discover quiz UI seeded with a curated list of titles you (the model) recommend. The user can then swipe to add or skip each one.

            USE THIS when the user wants an interactive picking session — "show me some 90s sci-fi to swipe through", "give me a quiz of cozy weekend films", "pick something for me to choose from". The seeded cards appear instantly (no extra LLM round-trip).

            Pass `mood` as a short user-facing label describing the set ("cozy 90s comedy", "feel-good documentaries"). This shows as the breadcrumb chip in the overlay and the resume card in chat.

            Aim for a deck of 10–25 cards — enough to be worth swiping. That is the deck SIZE, not the list length: titles the user already owns are dropped here before the deck is built (with library_mode "new"), so send enough to survive that. A small library: 20 picks is 20 cards. A large one: send 40–60, because most of the canon will be dropped. Up to 60 are accepted. Include `year` whenever you can — it disambiguates remakes. All picks share one `kind`.

            ONE DECK PER REQUEST. If the user's ask spans both movies and shows (or is vague about kind), pick the single most relevant `kind` (default to "movie" when ambiguous) and fill the deck with that — do NOT call the tool twice in the same turn for different kinds, as that opens two separate quiz sessions and confuses the user. A second call after the tool told you every pick was already owned is not a second deck: that is the same deck, corrected — but correct it with a checked list, not another guess.

            Pass `append: true` when the user asks for MORE picks continuing the current vibe — that extends the active deck instead of starting over.

            Set `library_mode` from the user's intent: "new" (default) excludes titles already in their library; "library" fills the deck from titles they own — use it when they want to rediscover their collection.

            Do NOT pre-check with `check_titles`: this tool already drops owned titles for you (library_mode "new"), so checking first is the same work twice. Just reach past the obvious — a 3000-film collection has Inception and The Empire Strikes Back — and send enough that plenty survives.

            When the user asks for MORE picks following an active session, pass `anchor_tmdb_ids` containing the TMDB IDs of titles they kept — the backend will fetch TMDB's similar-to graph for those anchors and merge it with your curated picks for stronger relevance.

            This is a single-shot session — there is no automatic top-up. When the user wants more, they'll ask explicitly via the chat.

            DO NOT use this for browsing curiosity without a swipe intent — use `suggest_titles` for that.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mood": .object([
                        "type": .string("string"),
                        "description": .string("Short user-facing label for the set; shown as the breadcrumb chip and resume card title."),
                    ]),
                    "kind": .object([
                        "type": .string("string"),
                        "description": .string("'series' to resolve picks through Sonarr, 'movie' through Radarr. All items in one call must share a kind."),
                    ]),
                    "items": .object([
                        "type": .string("array"),
                        "description": .string("Ordered list of picks; order is preserved in the quiz deck."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "title": .object([
                                    "type": .string("string"),
                                    "description": .string("The work's title."),
                                ]),
                                "year": .object([
                                    "type": .string("integer"),
                                    "description": .string("Optional release year — disambiguates remakes."),
                                ]),
                            ]),
                            "required": .array([.string("title")]),
                        ]),
                    ]),
                    "append": .object([
                        "type": .string("boolean"),
                        "description": .string("When true, append these picks to the user's active quiz session instead of starting a fresh one. Use this when the user explicitly asked for MORE picks in the same vibe (continuing the existing session). Defaults to false (fresh session)."),
                    ]),
                    "library_mode": .object([
                        "type": .string("string"),
                        "description": .string("'new' (default) = only titles NOT in the user's library — something to discover. 'library' = titles they already own — rediscovering their collection. Decide from the user's intent."),
                    ]),
                    "anchor_tmdb_ids": .object([
                        "type": .string("array"),
                        "description": .string("TMDB IDs of titles the user has kept (right-swiped) in the current session. When provided, the backend fetches TMDB's similar-to graph for each anchor and merges those results with your curated picks. Pass this from the 'More picks' prompt context where the user's kept titles + their TMDB IDs are listed. Cap at 5 anchor IDs."),
                        "items": .object([
                            "type": .string("integer"),
                        ]),
                    ]),
                ]),
                "required": .array([.string("mood"), .string("kind"), .string("items")]),
            ])
        ),
    ]

    // MARK: - Unified calendar (all arrs)

    private static let calendarTools: [MCPTool] = [
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

    private static let healthTools: [MCPTool] = [
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

    // MARK: - Media server (Plex / Jellyfin / Emby)

    private static let mediaServerTools: [MCPTool] = [
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

    // MARK: - Single-title details (+ optional cast)

    private static let titleDetailsTools: [MCPTool] = [
        MCPTool(
            name: "get_title_details",
            description: """
            Fetch full details for ONE movie (Radarr) or series (Sonarr) already in the library: overview/synopsis, year, runtime, genres, rating, status — and OPTIONALLY the cast.

            USE THIS to answer "tell me about X", "what's the plot of X", "who's in X?", "give me the cast of X". For the plot alone, leave `include_cast` off. Set `include_cast: true` whenever the user asks who is in a title ("kto wystąpił w X", "who starred in X", "cast of X") — the cast comes back as a strip of tappable headshots in the UI, and each name carries its personId so you can link it or pull that person's filmography without another name lookup. Leave it off otherwise; it costs an extra call and tokens. Movie cast comes from Radarr itself; SERIES cast comes from TMDB and needs a TMDB key — without one the tool says so.

            Resolve `id` first: `seriesId` from `sonarr_get_series`, `movieId` from `radarr_get_movies` — or either from `check_titles`, which returns them for a whole list at once. Output is plain text (no cards).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "service": .object([
                        "type": .string("string"),
                        "enum": .array([.string("sonarr"), .string("radarr")]),
                        "description": .string("'sonarr' for a series, 'radarr' for a movie."),
                    ]),
                    "id": .object([
                        "type": .string("integer"),
                        "description": .string("The arr's internal id: seriesId (sonarr_get_series) or movieId (radarr_get_movies). NOT the tmdbId."),
                    ]),
                    "include_cast": .object([
                        "type": .string("boolean"),
                        "description": .string("Set true to also fetch the cast from TMDB. Defaults to false — only enable when the user asks about actors/cast (extra call + tokens, needs a TMDB key)."),
                    ]),
                ]),
                "required": .array([.string("service"), .string("id")]),
            ])
        ),
    ]

    // MARK: - Custom formats (TRaSH-style quality scoring)

    private static let customFormatTools: [MCPTool] = [
        MCPTool(
            name: "custom_formats",
            description: """
            Inspect the custom formats on Sonarr or Radarr — the named release-matching rules (e.g. 'Bluray Tier 01', 'x265 (HD)', 'Repack/Proper', 'LQ') that drive TRaSH-style quality scoring. TWO MODES:
            • Omit `name`/`id` → LIST every format (id, name, condition count). USE for "what custom formats do I have?", "list my Radarr formats".
            • Pass `name` or `id` → DESCRIBE that one in detail: the conditions it matches (release-title regex, source, resolution, language, release group, with negate/required flags) AND the score it carries in each quality profile (e.g. '+100 in HD Bluray, 0 in Any'). USE for "what does 'LQ' match?", "how is x265 scored?", "what does 'Bluray Tier 01' do?".

            CRUCIAL for "why did Sonarr/Radarr grab this upgrade when my existing file looks better / is higher resolution?": an *arr upgrade is decided by total CUSTOM-FORMAT SCORE plus the quality-profile's quality ranking — NOT by what looks better to a human. A 1080p release can legitimately replace a 2160p one if it scores higher (better release group, repack/proper, preferred audio, no unwanted format, etc.). After `list_download_queue` shows the old→new score delta, describe the custom format(s) that differ between the two files to name exactly which rule earned (or cost) the points.

            The `service` argument is required. Output is plain text (no cards).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "service": .object([
                        "type": .string("string"),
                        "enum": .array([.string("sonarr"), .string("radarr")]),
                        "description": .string("Which arr to query: 'sonarr' or 'radarr'."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Optional. A custom format name (case-insensitive, partial match allowed), e.g. 'Bluray Tier 01' or 'x265' — switches to describe-one mode. Omit (with no `id`) to list all."),
                    ]),
                    "id": .object([
                        "type": .string("integer"),
                        "description": .string("Optional. A custom format id (from the list mode) — switches to describe-one mode. Omit (with no `name`) to list all."),
                    ]),
                ]),
                "required": .array([.string("service")]),
            ])
        ),
    ]

    // MARK: - Queue

    private static let queueTools: [MCPTool] = [
        MCPTool(
            name: "list_download_queue",
            description: """
            List the active Sonarr/Radarr download queue — what is currently downloading, queued, importing, or stalled. Each item shows its status and progress.

            When an item is an UPGRADE of a file already in the library, the result ALSO reports the existing file's quality / custom formats / score / size alongside the incoming release's (rendered as `UPGRADE: <old> → <new>`). USE that diff to explain to the user how the two differ and WHY the new release is better — higher resolution, better source (e.g. Bluray/Remux over WEB), added HDR/Dolby Vision, higher custom-format score, etc.

            If the user is SURPRISED an upgrade happened ("why did it replace my file, the old one looks better / is higher resolution?"), remember *arr upgrades are driven by the quality-profile's custom-format SCORE and quality ranking, not by what looks better to a human. When the score is what differs, follow up with `custom_formats` (passing the format name) on the custom format(s) that changed between old and new to name exactly which rule tipped the decision.

            USE THIS for "what's downloading?", "what's in the queue?", "what upgrades are pending?", "why is this upgrade better?", "why was this upgraded?". Results also surface as comparison cards in the chat. Optional `query` filters by title substring (case-insensitive).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional title substring (case-insensitive) to filter the queue, e.g. 'Dune' or 'The Wire'. Omit to list the whole queue."),
                    ]),
                ]),
            ])
        ),
    ]
}
