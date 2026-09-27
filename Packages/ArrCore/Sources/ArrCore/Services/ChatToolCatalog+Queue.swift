import Foundation

nonisolated extension ChatToolCatalog {

    // MARK: - Queue

    static let queueTools: [MCPTool] = [
        MCPTool(
            name: "list_download_queue",
            description: """
            List the active download queue across every configured arr — Sonarr, Radarr, Lidarr and Whisparr — covering what is currently downloading, queued, importing, or stalled. Each item shows its status and progress, and which service it belongs to. This is the WHOLE queue: don't tell the user music or a scene isn't downloading because you only looked at TV and movies.

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
