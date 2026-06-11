import Foundation

/// The current health of one monitored service.
///
///  - `.unknown` — not checked yet (or just became configured). Renders grey;
///    deliberately NOT green, so a configured-but-unchecked service never looks
///    healthy until a probe actually passes.
///  - `.ok` — last healthcheck passed. `detail` carries the version string when
///    the client returns one.
///  - `.down` — healthcheck failed (after the debounce). `message` is the
///    underlying error for the tooltip / Needs-You detail line.
public enum ConnectionHealthState: Equatable, Sendable {
    case unknown
    case ok(detail: String?)
    case down(message: String)

    public var isDown: Bool {
        if case .down = self { return true }
        return false
    }
}

public struct ServiceHealthSnapshot: Equatable, Sendable {
    public let state: ConnectionHealthState
    public let lastChecked: Date?

    public init(state: ConnectionHealthState, lastChecked: Date?) {
        self.state = state
        self.lastChecked = lastChecked
    }

    public static let unknown = ServiceHealthSnapshot(state: .unknown, lastChecked: nil)
}
