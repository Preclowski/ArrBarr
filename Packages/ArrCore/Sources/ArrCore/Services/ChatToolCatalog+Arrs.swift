import Foundation

nonisolated extension ChatToolCatalog {

    // MARK: - Sonarr

    static let sonarrTools: [MCPTool] = [
        MCPTool(
            name: "sonarr_search",
            description: "Search Sonarr's metadata source (TVDB) for a TV series to ADD. Results surface in the chat as tappable cards — the user opens each one and confirms profile / folder / quality in the SearchAddPanel to actually add it. You do NOT add anything yourself; there is no `sonarr_add_*` tool. Briefly explain WHY this set after the call. NOT for questions ABOUT a title ('tell me about X', plot, trivia) — answer those from your own knowledge; reach for check_titles/get_title_details only when their library state matters. SERIES only: anime feature films (Ghibli, Satoshi Kon) are movies → radarr_search. One empty result is the answer — never retry with a rephrasing.",
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
                    "sortBy": .object([
                        "type": .string("string"),
                        "description": .string("Deterministic ordering: rating, year, added, title, random — optionally .asc/.desc ('rating' = rating.desc). USE WITH limit for 'top N' questions, e.g. sortBy 'rating' + limit 10."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Max rows to return (cap 100). Pair with sortBy — 'top 10' means limit 10, not reading 100 rows and ranking them yourself."),
                    ]),
                    "count_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Return only the matched/total counts, no rows. Cheap way to size a filter before asking for rows."),
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

    static let radarrTools: [MCPTool] = [
        MCPTool(
            name: "radarr_search",
            description: "Search Radarr's metadata source (TMDB) for a movie to ADD. Results surface in the chat as tappable cards — the user opens each one and confirms profile / folder / quality in the SearchAddPanel to actually add it. You do NOT add anything yourself; there is no `radarr_add_*` tool. Briefly explain WHY this set after the call. NOT for questions ABOUT a title ('tell me about X', plot, trivia) — answer those from your own knowledge; reach for check_titles/get_title_details only when their library state matters. One empty result is the answer — never retry with a rephrasing.",
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
                    "sortBy": .object([
                        "type": .string("string"),
                        "description": .string("Deterministic ordering: rating, year, added, title, random — optionally .asc/.desc ('rating' = rating.desc). USE WITH limit for 'top N' questions: sortBy 'rating' + limit 10 answers 'my 10 best unwatched films' exactly, in one call."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Max rows to return (cap 100). Pair with sortBy — 'top 10' means limit 10, not reading 100 rows and ranking them yourself."),
                    ]),
                    "count_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Return only the matched/total counts, no rows. Cheap way to size a filter before asking for rows."),
                    ]),
                ]),
            ])
        ),
        MCPTool(
            name: "radarr_search_movie",
            description: "Force an indexer search for one movie the user ALREADY HAS in Radarr. USE for 'this didn't download, try again', 'spróbuj ściągnąć ponownie', 'try to grab a better quality of X'. NEVER the second step of adding a movie: adding finishes when the USER taps a card from radarr_search and confirms in the add panel — there is no tool for it, and calling this with a not-in-library id (or a tmdbId) does nothing. Returns confirmation text; results land in the queue when indexers respond.",
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

    static let lidarrTools: [MCPTool] = [
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

    static let whisparrTools: [MCPTool] = [
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
}
