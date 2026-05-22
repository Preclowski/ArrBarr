import Foundation

/// Common shape of "thing that can run a chat tool by name."
/// Implemented by MCPClient (network/JSON-RPC) and LocalToolBackend (in-process).
public protocol ToolBackend: Sendable {
    func listTools() async throws -> [MCPTool]
    func callTool(name: String, arguments: JSONValue) async throws -> String
}

// MCPClient already satisfies the protocol once its callTool returns String.
extension MCPClient: ToolBackend {}
