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
