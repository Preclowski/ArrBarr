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
nonisolated public enum ConnectionHealthState: Equatable, Sendable {
    case unknown
    case ok(detail: String?)
    case down(message: String)

    public var isDown: Bool {
        if case .down = self { return true }
        return false
    }
}

nonisolated public struct ServiceHealthSnapshot: Equatable, Sendable {
    public let state: ConnectionHealthState

    public init(state: ConnectionHealthState) {
        self.state = state
    }

    public static let unknown = ServiceHealthSnapshot(state: .unknown)
}
