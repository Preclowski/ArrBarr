import Foundation

nonisolated extension ChatToolCatalog {

    // MARK: - Queue

    static let queueTools: [ToolDefinition] = [
        ToolDefinition(
            name: "list_download_queue",
            description: """
            List the active download queue across every configured arr — Sonarr, Radarr, Lidarr and Whisparr — covering what is currently downloading, queued, importing, or stalled. Each item shows its status and progress, and which service it belongs to. This is the WHOLE queue: don't tell the user music or a scene isn't downloading because you only looked at TV and movies.

            Every row also carries its incoming release: release name, quality (with Proper/Repack), custom-format score, the custom formats it matched, size and the title's quality profile. ANSWER quality / custom-format / "which profile" questions straight from these lines — no other tool knows more about a queued release. A Sonarr season pack is one row.

            When a row is an UPGRADE of a file already in the library, a second line diffs the existing file against the incoming release (`UPGRADE: <old> → <new> · score <old>→<new> · +gained -lost · <old size>→<new size>`). USE it to explain how the two differ and WHY the new release wins — higher resolution, better source (Bluray/Remux over WEB), added HDR/Dolby Vision, a Proper/Repack, a higher custom-format score.

            If the user is SURPRISED an upgrade happened ("why did it replace my file, the old one looks better / is higher resolution?"), remember *arr upgrades are driven by the quality profile's custom-format SCORE and quality ranking, not by what looks better to a human. When the score is what differs, call `custom_formats` ONCE with `names` set to every format that changed (the +/- ones) to name exactly which rule tipped the decision, reading the score from the row's profile.

            USE THIS for "what's downloading?", "what's in the queue?", "what upgrades are pending?", "why is this upgrade better?", "why was this upgraded?", "what quality / which custom formats is X downloading with?". Results also surface as comparison cards in the chat. Optional `query` filters by title, episode or release name (case-insensitive substring).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional case-insensitive substring of the title, episode (e.g. 'S02E03') or release name, e.g. 'Dune' or 'The Wire'. Omit to list the whole queue."),
                    ]),
                ]),
            ])
        ),
    ]
}
