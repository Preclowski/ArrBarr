import Foundation

nonisolated extension ChatToolCatalog {

    // MARK: - Curated suggestions (model-knowledge picks → rich cards)
    //
    // For taste-based queries the model picks from its own associations; the tool
    // resolves each through the arr lookup into real, tappable cards.

    static let suggestTools: [ToolDefinition] = [
        ToolDefinition(
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
        ToolDefinition(
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
                                "tmdbId": .object([
                                    "type": .string("integer"),
                                    "description": .string("Optional TMDB id when you already hold one (from tmdb_* tools or earlier output). Resolves exactly — no wrong-remake risk — and skips the title search. Never guess it."),
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
        ToolDefinition(
            name: "discover_in_quiz",
            description: """
            Open the Discover quiz UI seeded with a curated list of titles you (the model) recommend. The user can then swipe to add or skip each one.

            USE THIS when the user wants an interactive picking session — "show me some 90s sci-fi to swipe through", "give me a quiz of cozy weekend films", "pick something for me to choose from". The seeded cards appear instantly (no extra LLM round-trip).

            Pass `mood` as a short user-facing label describing the set ("cozy 90s comedy", "feel-good documentaries"). This shows as the breadcrumb chip in the overlay and the resume card in chat.

            ARGUMENT ORDER: write `mood`, `kind`, `library_mode`, `append` and `source` FIRST and `items` LAST — cards start loading while you are still writing the list, but only once those are known.

            IN CINEMAS / AIRING NOW: for "currently in cinemas", "airing right now", "new this week" asks pass `source: "now"` and `items: []`. The deck then comes from TMDB's live listings — your training data cannot know today's releases, so never build such a deck from memory.

            Aim for a deck of 10–25 cards — enough to be worth swiping. That is the deck SIZE, not the list length: titles the user already owns are dropped here before the deck is built (with library_mode "new"), so send enough to survive that. A small library: 20 picks is 20 cards. A large one: send 40–60, because most of the canon will be dropped. Up to 60 are accepted. Include `year` whenever you can — it disambiguates remakes. All picks share one `kind`.

            ONE DECK PER REQUEST — never call this tool twice in one turn. Once a call reports "Opened Discover quiz", that deck IS the answer: a small deck (picks dropped as owned or recently skipped) is still the deck, and rebuilding it opens duplicate sessions and reads as a loop. The single exception: when the tool says EVERY pick was already owned, you get one corrective call seeded from a check_titles-verified list — one, never a third.

            Pass `append: true` when the user asks for MORE picks continuing the current vibe — that extends the active deck instead of starting over. Size appended rounds so ~10-15 FRESH cards actually land after owned/shown/skipped filtering: send 25-40 picks per round, never a handful — a round that lands 2 cards just makes the user watch loading again two swipes later.

            Set `library_mode` from the user's intent: "new" (default) excludes titles already in their library; "library" fills the deck from titles they own — use it when they want to rediscover their collection. With library_mode "library" you may pass `items: []` and `genre` / `startYear` / `endYear` instead: the deck is then drawn straight from their library snapshot (instant, watched titles excluded, top-rated pool with a random draw) — prefer that over inventing a list of titles they own.

            Do NOT pre-check with `check_titles`: this tool already drops owned titles for you (library_mode "new"), so checking first is the same work twice. Just reach past the obvious — a 3000-film collection has Inception and The Empire Strikes Back — and send enough that plenty survives.

            When the user asks for MORE picks following an active session, the backend already anchors the round on the titles they kept this session (TMDB's similar-to graph, merged after your curated picks). Pass `anchor_tmdb_ids` only to steer toward specific titles whose TMDB ids you hold.

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
                        "description": .string("Ordered list of picks; order is preserved in the quiz deck. Always present — [] only with library_mode 'library' or source 'now'."),
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
                                "tmdbId": .object([
                                    "type": .string("integer"),
                                    "description": .string("Optional TMDB id when you already hold one. Resolves exactly and skips the title search. Never guess it."),
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
                    "genre": .object([
                        "type": .string("string"),
                        "description": .string("library_mode 'library' only: genre filter for the library-drawn deck (same vocabulary as radarr_get_movies / sonarr_get_series)."),
                    ]),
                    "startYear": .object([
                        "type": .string("integer"),
                        "description": .string("library_mode 'library' only: inclusive lower bound on year for the library-drawn deck."),
                    ]),
                    "endYear": .object([
                        "type": .string("integer"),
                        "description": .string("library_mode 'library' only: inclusive upper bound on year for the library-drawn deck."),
                    ]),
                    "source": .object([
                        "type": .string("string"),
                        "description": .string("'now' builds the deck from TMDB's live listings: movies in cinemas, or series airing this week. Omit for your own picks."),
                    ]),
                    "anchor_tmdb_ids": .object([
                        "type": .string("array"),
                        "description": .string("Optional TMDB IDs to anchor the round on. Append rounds already anchor on the session's kept titles, so pass this only to steer. These MUST be TMDB ids — for series that is the tmdbTVId reported in tool output, NEVER a tvdbId. Cap at 5."),
                        "items": .object([
                            "type": .string("integer"),
                        ]),
                    ]),
                ]),
                "required": .array([.string("mood"), .string("kind"), .string("items")]),
            ])
        ),
    ]
}
