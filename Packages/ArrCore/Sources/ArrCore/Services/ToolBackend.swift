import Foundation

/// Common shape of "thing that can run a chat tool by name."
/// Implemented by LocalToolBackend (in-process).
public protocol ToolBackend: Sendable {
    func listTools() async throws -> [MCPTool]
    func callTool(name: String, arguments: JSONValue) async throws -> String
}
