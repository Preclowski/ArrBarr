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
    /// Result strings, aligned with `toolCalls` by index. If non-nil,
    /// the provider has already executed each call and the view-model
    /// should NOT re-execute them — render them as `.tool` messages.
    /// If nil, the view-model owns execution.
    public let toolResults: [String]?
    public init(text: String, toolCalls: [ToolCall] = [], toolResults: [String]? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.toolResults = toolResults
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
