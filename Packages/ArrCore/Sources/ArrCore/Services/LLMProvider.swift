import Foundation

public struct LLMTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct LLMResponse: Sendable {
    /// Free-text the assistant produced.
    public let text: String
    /// Zero or more tool calls the assistant made.
    public let toolCalls: [ToolCall]
    /// Results aligned with `toolCalls` by index. If non-nil, the provider
    /// has already executed each call and the view-model should NOT
    /// re-execute them — render them as `.tool` messages.
    /// If nil, the view-model owns execution.
    public let toolResults: [ToolCallOutput]?
    public init(text: String, toolCalls: [ToolCall] = [], toolResults: [ToolCallOutput]? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }
}

/// Shared bits for composing the chat system prompt across providers, so the
/// OpenAI and Foundation Models prompts stay in sync.
public enum SystemPromptComposer {
    /// Human-readable clause naming the arrs currently exposed to the model.
    /// Derived from the gated tool list (`sonarr_*`, `radarr_*`, …) so it always
    /// reflects exactly what's enabled — no separate config to keep in step.
    public static func arrsClause(tools: [LLMTool]) -> String {
        let known: [(prefix: String, label: String)] = [
            ("sonarr_", "Sonarr (TV)"),
            ("radarr_", "Radarr (movies)"),
            ("lidarr_", "Lidarr (music)"),
            ("whisparr_", "Whisparr (adult content)"),
        ]
        let present = known
            .filter { entry in tools.contains { $0.name.hasPrefix(entry.prefix) } }
            .map(\.label)
        // Join "a, b and c" style.
        switch present.count {
        case 0: return "your self-hosted *arr media stack"
        case 1: return present[0]
        case 2: return "\(present[0]) and \(present[1])"
        default: return present.dropLast().joined(separator: ", ") + " and " + present[present.count - 1]
        }
    }

    /// In-text linking rules. Shared verbatim by both providers — the URL forms
    /// here are the ones `ChatLink` parses, and a link that doesn't match them
    /// is rendered as ordinary text, so the wording is deliberately narrow about
    /// where the ids may come from.
    public static let linkingClause = """
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

public protocol LLMProvider: Sendable {
    /// Whether the provider is usable at runtime (e.g. Foundation Models requires macOS 26 + AI on).
    var isAvailable: Bool { get }
    /// One round of LLM. The view-model is responsible for the loop:
    ///   send -> respond -> (run tool calls) -> send tool results -> respond -> ...
    func respond(prompt: String, tools: [LLMTool], history: [ChatMessage]) async throws -> LLMResponse
}

/// Fallback provider that says "I'm not available." Useful when no provider has been set up
/// yet, so the chat UI can render an unavailable banner instead of crashing.
public struct UnavailableLLMProvider: LLMProvider {
    public init() {}
    public var isAvailable: Bool { false }
    public func respond(prompt: String, tools: [LLMTool], history: [ChatMessage]) async throws -> LLMResponse {
        LLMResponse(text: "Chat is unavailable.")
    }
}
