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
            name: "sonarr_get_calendar",
            description: "Get upcoming TV episode releases from Sonarr (next ~7 days, items already monitored).",
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
            name: "sonarr_get_series",
            description: "List TV series currently in the Sonarr library by TITLE. Use ONLY when the user names a specific show title. DO NOT use this to find shows by actor, director, genre, or year — the library record has no cast / crew / genre metadata. For those queries use tmdb_search_person + tmdb_person_tv_credits (or tmdb_discover_series).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional title substring (case-insensitive). Omit to list all series — produces a large dump, prefer a query."),
                    ]),
                ]),
            ])
        ),
    ]

    // MARK: - Radarr

    private static let radarrTools: [MCPTool] = [
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
            name: "radarr_get_calendar",
            description: "Get upcoming movie releases from Radarr (next ~7 days, items already monitored).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
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
            name: "radarr_get_movies",
            description: "List movies currently in the Radarr library by TITLE. Use ONLY when the user names a specific movie title. DO NOT use this to find movies by actor, director, genre, or year — the library record has no cast / crew / genre metadata, so a query like 'Adam Sandler' returns nothing useful. For those queries use tmdb_search_person + tmdb_person_movie_credits (or tmdb_discover_movies) — those tools already cross-reference results with the library and mark which are owned.",
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
    ]

    // MARK: - Lidarr

    private static let lidarrTools: [MCPTool] = [
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

    // MARK: - Whisparr

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
            description: "List TV series a person appears in (or created), sorted by popularity. Use after tmdb_search_person. Sonarr indexes by TVDB id but accepts a TMDB id lookup, so taps still route to sonarr_add_series.",
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
}
