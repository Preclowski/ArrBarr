import Foundation
import Observation

/// Its own `@Observable` model, not a `ConfigStore` property: status pushes arrive even with Settings closed
/// and would invalidate every view observing the store.
@Observable
public final class MCPServerStatusModel {
    public static let shared = MCPServerStatusModel()

    public var status: MCPServerStatus = .stopped

    init() {}
}
