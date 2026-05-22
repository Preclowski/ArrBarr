import Foundation

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, assistant, tool }

    public let id: UUID
    public let role: Role
    public var content: String
    /// Set when the assistant is requesting a tool call.
    public var toolCall: ToolCall?
    /// Set on `.tool` messages — the text returned by the MCP server.
    public var toolResult: String?
    public let timestamp: Date

    public init(id: UUID = UUID(), role: Role, content: String,
                toolCall: ToolCall? = nil, toolResult: String? = nil,
                timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCall = toolCall
        self.toolResult = toolResult
        self.timestamp = timestamp
    }
}

public struct ToolCall: Equatable, Sendable {
    /// Provider-side correlation id (e.g. OpenAI's tool_call_id). Optional;
    /// Foundation Models doesn't need this, OpenAI does.
    public let id: String?
    public let name: String
    public let arguments: JSONValue
    public init(id: String? = nil, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}
