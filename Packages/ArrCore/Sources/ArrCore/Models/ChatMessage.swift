import Foundation
import MediaKit

nonisolated struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable { case user, assistant, tool }

    let id: UUID
    let role: Role
    var content: String
    var toolCall: ToolCall?
    /// Set on `.tool` messages: the text result the model sees.
    var toolResult: String?
    /// Set on `.tool` messages: UI-only payload, never sent to the model.
    var richContent: ChatRichContent?

    init(id: UUID = UUID(),
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

extension JSONValue {
    /// A model's raw argument string. Anything but an object stays a string so the backend refuses it
    /// with a message the model can act on, instead of running the tool with no arguments.
    nonisolated static func toolArguments(_ raw: String) -> JSONValue {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .object([:]) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
              case .object = value else { return .string(raw) }
        return value
    }
}
