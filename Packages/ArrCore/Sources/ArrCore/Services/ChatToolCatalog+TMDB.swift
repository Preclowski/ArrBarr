import Foundation

nonisolated extension ChatToolCatalog {

    // MARK: - TMDB shared (person lookup feeds both movie + tv credits)

    static let tmdbSharedTools: [MCPTool] = [
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

    static let tmdbMovieTools: [MCPTool] = [
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

    static let tmdbSeriesTools: [MCPTool] = [
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
}
