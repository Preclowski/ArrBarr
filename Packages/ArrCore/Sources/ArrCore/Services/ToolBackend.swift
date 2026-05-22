import Foundation

/// The combined output of a tool call: text for the LLM and optional rich UI payload.
public struct ToolCallOutput: Sendable {
    /// Condensed text returned to the LLM (low token cost).
    public let text: String
    /// Structured payload for the UI (never sent to the LLM).
    public let rich: ChatRichContent?

    public init(text: String, rich: ChatRichContent? = nil) {
        self.text = text
        self.rich = rich
    }
}

/// Common shape of "thing that can run a chat tool by name."
/// Implemented by LocalToolBackend (in-process).
public protocol ToolBackend: Sendable {
    func listTools() async throws -> [MCPTool]
    func callTool(name: String, arguments: JSONValue) async throws -> ToolCallOutput
}
