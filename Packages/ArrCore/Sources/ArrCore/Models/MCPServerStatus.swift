import Foundation

/// Live status of the in-app MCP server, surfaced in Settings. Set by the macOS
/// app's `MCPServerController`; `ArrCore` only models and displays it.
public enum MCPServerStatus: Equatable, Sendable {
    case stopped
    case running(url: String)
    case failed(message: String)
}
