import Foundation
import MediaKit

nonisolated public struct LLMTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

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
    static func arrsClause(tools: [LLMTool]) -> String {
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
}

protocol LLMProvider: Sendable {
    /// Whether the provider is usable at runtime (e.g. Foundation Models requires macOS 26 + AI on).
    var isAvailable: Bool { get }
    /// One round of LLM; the view-model runs the tool-call loop.
    func respond(prompt: String, tools: [LLMTool], history: [ChatMessage]) async throws -> LLMResponse
}

struct UnavailableLLMProvider: LLMProvider {
    init() {}
    var isAvailable: Bool { false }
    func respond(prompt: String, tools: [LLMTool], history: [ChatMessage]) async throws -> LLMResponse {
        LLMResponse(text: String(localized: "chat.unavailable.label", bundle: .module))
    }
}
