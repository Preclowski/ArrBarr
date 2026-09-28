import Foundation
import MediaKit

nonisolated public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, assistant, tool }

    public let id: UUID
    public let role: Role
    public var content: String
    public var toolCall: ToolCall?
    /// Set on `.tool` messages: the text result the model sees.
    public var toolResult: String?
    /// Set on `.tool` messages: UI-only payload, never sent to the model.
    public var richContent: ChatRichContent?

    public init(id: UUID = UUID(),
                role: Role,
                content: String,
                toolCall: ToolCall? = nil,
                toolResult: String? = nil,
                richContent: ChatRichContent? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCall = toolCall
        self.toolResult = toolResult
        self.richContent = richContent
    }
}

nonisolated public struct ToolCall: Equatable, Sendable {
    /// Provider-side correlation id (OpenAI's tool_call_id); Foundation Models doesn't use it.
    public let id: String?
    public let name: String
    public let arguments: JSONValue
    public init(id: String? = nil, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}
