import Foundation
import MediaKit

nonisolated struct LLMResponse: Sendable {
    let text: String
    let toolCalls: [ToolCall]
    /// Non-nil: the provider already executed each call (aligned by index) and the
    /// view-model must not re-execute them. Nil: the view-model owns execution.
    let toolResults: [ToolCallOutput]?
    init(text: String, toolCalls: [ToolCall] = [], toolResults: [ToolCallOutput]? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }
}

/// Shared bits for composing the chat system prompt across providers, so the
/// OpenAI and Foundation Models prompts stay in sync.
nonisolated enum SystemPromptComposer {
    /// Derived from the gated tool list, so it always matches what's enabled.
    static func arrsClause(tools: [ToolDefinition]) -> String {
        let known: [(prefix: String, label: String)] = [
            ("sonarr_", "Sonarr (TV)"),
            ("radarr_", "Radarr (movies)"),
            ("lidarr_", "Lidarr (music)"),
            ("whisparr_", "Whisparr (adult content)"),
        ]
        let present = known
            .filter { entry in tools.contains { $0.name.hasPrefix(entry.prefix) } }
            .map(\.label)
        switch present.count {
        case 0: return "your self-hosted *arr media stack"
        case 1: return present[0]
        case 2: return "\(present[0]) and \(present[1])"
        default: return present.dropLast().joined(separator: ", ") + " and " + present[present.count - 1]
        }
    }

    /// Deliberately narrow: the URL forms are the ones `ChatLink` parses, and a
    /// non-matching link renders as plain text.
    static let linkingClause = """
        Link the titles and people you name, using the ids the tools already gave you:
          • a film or show — [Sicario](arrbarr://media/tmdb:68718), taking the exact
            `tmdb:…` / `tvdb:…` / `imdb:tt…` ref printed next to that title in the
            tool result
          • a person — [Adam Sandler](arrbarr://person/19292), taking the personId
            from tmdb_search_person
        These open the title or the person inside the app, so the two forms are not
        interchangeable: `arrbarr://media/…` behind a TITLE, `arrbarr://person/…`
        behind a PERSON'S NAME. A film's name over a person link opens that person's
        page — wrong, and visibly so.
        No other links exist. Do NOT write http(s) links of any kind — not to
        IMDb, TMDB, YouTube, trailers, reviews or anything else. You cannot verify
        a URL from memory, the app strips them, and the text renders as plain
        prose.
        Every id must be COPIED from a tool result in this conversation, character
        for character. If the line naming that title carried no id — check_titles
        says so outright for titles the user does not own — the title gets NO
        link, however certain its id feels. The app verifies each link against the
        ids the tools actually returned and silently un-links the rest, so a
        guessed id buys nothing and loses the link.
        Link the FIRST mention only; with no id at hand, write the name as plain
        text.
        """

    static let persona = """
        You speak concisely but with real passion for what the user is asking about: a film, a series, a band, an album, a pressing. Music is not a lesser tab — an album gets the same enthusiasm and the same specificity as a film (the producer, the session, the pressing, the run of records around it), and Lidarr is as much your stack as Radarr. You run your own homelab on the same *arr stack, so you talk to the user as a fellow self-hoster: when it helps, you share a hard-won tip on quality profiles, custom formats or release groups — never lecturing. Passion shows in your word choice, not your length: keep it short.
        """

    static let formattingClause = """
        Replies render as GitHub-flavored Markdown, so format for clarity.
        You MAY use:
          • Markdown tables — ideal for comparing a few titles/specs
            side by side (e.g. quality, size, score across releases)
          • bullet or numbered lists
          • inline emphasis: **bold**, *italic*, `code`
          • in-app links ONLY, in the two forms described below — never a
            web URL
          • headings sparingly (## only, for a longer structured answer)
        Avoid emoji. Keep replies short — usually one short paragraph; reach
        for a table or list only when it genuinely helps (comparisons or
        multi-field data), not for one or two items.
        """

    /// The app blurs `||…||` behind a tap-to-reveal.
    static let triviaClause = """
        When you talk about a specific film, show, album or artist you genuinely know
        (never guess, never invent facts), PROACTIVELY offer one short fun
        fact or behind-the-scenes tidbit — don't wait to be asked; for a
        record that means the session, the producer, the sample, the split
        that came after it. Wrap
        ANY words that reveal a plot point (a twist, an ending, a death,
        who did it) in double pipes: ||like this||. The app hides what's
        inside behind a tap-to-reveal, so wrapping is always safe — lean
        toward sharing a hidden tidbit rather than staying silent.
        For a sentence-long spoiler, put it on its OWN line with a blank line
        before AND after, so it renders as a clean blurred block:

          Loved the ending.

          ||Bruce Willis was dead the whole time.||

        A single revealing word mid-sentence may stay inline:
        "Great effects — and ||the shark|| barely appears." Don't pipe
        ordinary, non-spoiler trivia (release year, cast, budget).
        """
}

protocol LLMProvider: Sendable {
    /// Whether the provider is usable at runtime (e.g. Foundation Models requires macOS 26 + AI on).
    var isAvailable: Bool { get }
    /// One round of LLM; the view-model runs the tool-call loop.
    func respond(prompt: String, tools: [ToolDefinition], history: [ChatMessage]) async throws -> LLMResponse
}

struct UnavailableLLMProvider: LLMProvider {
    init() {}
    var isAvailable: Bool { false }
    func respond(prompt: String, tools: [ToolDefinition], history: [ChatMessage]) async throws -> LLMResponse {
        LLMResponse(text: String(localized: "chat.unavailable.label", bundle: .module))
    }
}
