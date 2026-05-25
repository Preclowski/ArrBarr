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
        includeTMDBSeries: Bool = false
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
        // discover_in_tinder requires at least one arr so the Discover
        // tab is available.
        if includeSonarr || includeRadarr {
            arr.append(contentsOf: discoverTinderTools)
        }
        // arr_health needs at least one arr to query.
        if includeSonarr || includeRadarr || includeLidarr || includeWhisparr {
            arr.append(contentsOf: healthTools)
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
        includeTMDBSeries: Bool = false
    ) -> [LLMTool] {
        tools(includeSonarr: includeSonarr, includeRadarr: includeRadarr,
              includeLidarr: includeLidarr, includeWhisparr: includeWhisparr,
              includeTMDBMovies: includeTMDBMovies, includeTMDBSeries: includeTMDBSeries).map {
            LLMTool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
        }
    }

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
            name: "sonarr_get_calendar",
            description: "Get upcoming TV episode releases from Sonarr (next ~7 days, items already monitored).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        MCPTool(
            name: "sonarr_get_series",
            description: "List TV series in the Sonarr library by TITLE — also returns each series' `seriesId` plus per-season monitor state and have/total episode counts (`S1 ✓ 10/10, S2 ✗ 0/10`). USE this to answer 'do I have season N monitored?', 'which seasons of X am I tracking?', 'find seriesId for X'. The seriesId returned here is what `sonarr_monitor_season` and `sonarr_search_episodes` expect. With `seasonNumber` argument the output zooms in on one season so you don't pay for the whole list. DO NOT use this for person / genre queries — that's tmdb_*. DO NOT use this for service health — that's `arr_health`.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional title substring (case-insensitive). Omit to list all series — produces a large dump, prefer a query."),
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
            description: "Flip monitoring on a single season. When state=true, ALSO fires a SeasonSearch automatically — there is no opt-out, because chat requests like 'pobierz mi 3 sezon' / 'monitor S3' always mean 'and grab it'. When state=false, no search runs. The result text REPORTS THE ACTUAL OUTCOME ('OK', 'PARTIAL', or 'FAILED'); relay that to the user faithfully — do not claim success if the result says PARTIAL or FAILED.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "seriesId": .object([
                        "type": .string("integer"),
                        "description": .string("Sonarr series id. Get via sonarr_get_series."),
                    ]),
                    "seasonNumber": .object([
                        "type": .string("integer"),
                        "description": .string("Season number (1-based, ignore season 0 specials)."),
                    ]),
                    "state": .object([
                        "type": .string("boolean"),
                        "description": .string("true = monitor + search, false = unmonitor (no search). Defaults to true."),
                    ]),
                ]),
                "required": .array([.string("seriesId"), .string("seasonNumber")]),
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
            name: "radarr_get_calendar",
            description: "Get upcoming movie releases from Radarr (next ~7 days, items already monitored).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        MCPTool(
            name: "radarr_get_movies",
            description: "List movies currently in the Radarr library by TITLE. Use ONLY when the user names a specific movie title. DO NOT use this to find movies by actor, director, genre, or year — the library record has no cast / crew / genre metadata, so a query like 'Adam Sandler' returns nothing useful. For those queries use tmdb_search_person + tmdb_person_movie_credits (or tmdb_discover_movies) — those tools already cross-reference results with the library and mark which are owned. For 'is Radarr healthy / what's the state of my arrs' use `arr_health` instead.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional title substring (case-insensitive). Omit to list all movies — produces a large dump, prefer a query."),
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
                        "description": .string("Radarr movie id. Get via radarr_get_movies or tmdb_person_movie_credits (the cross-reference there fills it in for owned movies)."),
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
            name: "lidarr_get_artist_albums",
            description: "List albums for one artist (resolved via lidarr_get_artists). Each entry carries `albumId`, title, type (Album / Single / EP / Live / Compilation / Soundtrack / Other), year, monitor state, and track-file progress. USE for 'which albums of X am I tracking?', 'what's new from X?', 'find albumId for Y'. Output is capped at 40 entries — pass `albumType` (e.g. 'Album') to narrow to studio LPs when an artist has dozens of live/compilation entries cluttering things.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "artistId": .object([
                        "type": .string("integer"),
                        "description": .string("Lidarr artist id. Resolve via lidarr_get_artists."),
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
        MCPTool(
            name: "whisparr_get_calendar",
            description: "Get upcoming scene releases from Whisparr (next ~30 days, items already monitored).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
    ]

    // MARK: - TMDB shared (person lookup feeds both movie + tv credits)

    private static let tmdbSharedTools: [MCPTool] = [
        MCPTool(
            name: "tmdb_search_person",
            description: "FIRST CHOICE for any question that mentions an actor, director, writer, or other person — including 'films/shows with X', 'what did X make', 'X's best movies'. Resolves a name to a TMDB personId. ALWAYS use this before tmdb_person_movie_credits or tmdb_person_tv_credits; never try to guess the personId. NEVER use radarr_get_movies or sonarr_get_series for person queries — those library tools don't carry cast/crew metadata and will return nothing.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Person's name, e.g. 'Adam Sandler' or 'Greta Gerwig'"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
    ]

    // MARK: - TMDB movies (gated on tmdbEnabled && Radarr configured)

    private static let tmdbMovieTools: [MCPTool] = [
        MCPTool(
            name: "tmdb_person_movie_credits",
            description: "List movies a person appears in (or directed/wrote), sorted by popularity. Use after tmdb_search_person. Results are pre-cross-referenced with the Radarr library — entries already owned are marked [OWNED] in the text and surface as 'In library' cards in the UI, so do NOT re-check with radarr_get_movies. tmdbId is included for the rest, so taps add to Radarr.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "personId": .object([
                        "type": .string("integer"),
                        "description": .string("TMDB person id from tmdb_search_person"),
                    ]),
                ]),
                "required": .array([.string("personId")]),
            ])
        ),
        MCPTool(
            name: "tmdb_discover_movies",
            description: "Discover movies by genre and/or year range. Use this for 'suggest a horror for tonight', 'films from the 90s', 'best sci-fi from the last 5 years'. Sorted by popularity by default. Results include tmdbId so taps add to Radarr.",
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
            name: "tmdb_person_tv_credits",
            description: "List TV series a person appears in (or created), sorted by popularity. Use after tmdb_search_person. Surfaces as tappable cards — user opens each in SearchAddPanel to add. Sonarr indexes by TVDB id but accepts a TMDB id lookup so the card flow works for TMDB-sourced results.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "personId": .object([
                        "type": .string("integer"),
                        "description": .string("TMDB person id from tmdb_search_person"),
                    ]),
                ]),
                "required": .array([.string("personId")]),
            ])
        ),
        MCPTool(
            name: "tmdb_discover_series",
            description: "Discover TV series by genre and/or year range. Use this for 'suggest a sci-fi series from the 2010s' or 'best comedy shows of the last 3 years'. Sorted by popularity by default.",
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
            name: "suggest_titles",
            description: """
            Present a curated list of titles you (the model) recommend from your own knowledge, rendered as interactive cards with posters / ratings / in-library state.

            USE THIS for taste-based queries: "suggest a show like Mr. Robot", "movies in the style of Wes Anderson", "something in the mood for noir tonight", "good follow-up to Breaking Bad". Your training-data associations are better than `tmdb_discover_*`'s algorithmic filters for these.

            DO NOT use `tmdb_discover_*` for taste queries — those are for genre/year filters ("popular 90s horror", "highly-rated documentaries 2023") where the user picks the dimension and you do not need to curate.

            Pass 5–12 picks. Include `year` whenever you're confident — it disambiguates remakes and same-titled works. All picks must share one `kind` per call (all series, or all movies). The tool will resolve each through Sonarr/Radarr; any pick that can't be found is silently dropped from the cards (and reported back to you) so the user only sees real, addable items.

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
                ]),
                "required": .array([.string("kind"), .string("items")]),
            ])
        ),
    ]

    // MARK: - Discover tinder launcher

    private static let discoverTinderTools: [MCPTool] = [
        MCPTool(
            name: "discover_in_tinder",
            description: """
                Open the Discover tab in tinder/swipe mode with a specific mood. \
                Use ONLY when the user explicitly asks to see suggestions in tinder, \
                swipe view, or discover. The user must clearly say they want a \
                swipeable picker — don't infer it from a casual recommendation request. \
                Example phrases: "show me X in tinder", "I want to swipe through X", \
                "open discover with X".
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mood": .object([
                        "type": .string("string"),
                        "description": .string("The user's mood description, e.g. '90s comedies with Adam Sandler'."),
                    ]),
                ]),
                "required": .array([.string("mood")]),
            ])
        ),
    ]

    // MARK: - Cross-arr status / diagnostics

    private static let healthTools: [MCPTool] = [
        MCPTool(
            name: "arr_health",
            description: """
            Aggregated health check across every configured arr (Sonarr, Radarr, Lidarr, Whisparr). Returns each service's warnings + errors — disconnected indexers, missing root folders, full disk, queue stuck, etc. Same bell-icon data each arr's own UI surfaces.

            USE THIS for "what's the state of my arrs", "is everything working", "are there any issues", "any problems with Sonarr". DO NOT use `sonarr_get_series` / `radarr_get_movies` for status questions — those list library contents and tell you nothing about whether the service is healthy.

            Output is plain text (no cards). Relay the per-service summary to the user briefly. Inline the most actionable warnings if any.
            """,
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
    ]
}
