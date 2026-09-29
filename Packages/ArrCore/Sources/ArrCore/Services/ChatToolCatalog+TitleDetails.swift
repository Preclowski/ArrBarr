import Foundation

nonisolated extension ChatToolCatalog {

    // MARK: - Single-title details (+ optional cast)

    static let titleDetailsTools: [ToolDefinition] = [
        ToolDefinition(
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

    static let customFormatTools: [ToolDefinition] = [
        ToolDefinition(
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
}
