import Foundation

/// `.unknown` renders grey, not green, so an unchecked service never looks
/// healthy until a probe passes.
nonisolated public enum ConnectionHealthState: Equatable, Sendable {
    case unknown
    case ok(detail: String?)
    case down(message: String)
}

nonisolated public struct ServiceHealthSnapshot: Equatable, Sendable {
    public let state: ConnectionHealthState

    public init(state: ConnectionHealthState) {
        self.state = state
    }

    public static let unknown = ServiceHealthSnapshot(state: .unknown)
}
