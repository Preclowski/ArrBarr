import Foundation
import Observation

/// Live status of the embedded MCP server, pushed in by the app
/// (`MCPServerController`) and read by one Settings pane. Never persisted.
///
/// Its own `@Observable` model rather than a property on `ConfigStore`: the
/// server pushes a status on every lifecycle transition, including while
/// Settings isn't open, and on an `ObservableObject` each of those invalidated
/// every view observing the store — the whole queue and library included — to
/// update a label nobody was looking at.
@Observable
public final class MCPServerStatusModel {
    public static let shared = MCPServerStatusModel()

    public var status: MCPServerStatus = .stopped

    init() {}
}
