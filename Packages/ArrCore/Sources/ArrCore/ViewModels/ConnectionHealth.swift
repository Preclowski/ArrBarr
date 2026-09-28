import Foundation
import SwiftUI

/// App-wide connection health per monitored service. Failures are debounced over `downThreshold` strikes;
/// a configured but unconfirmed service stays `.unknown`, never green.
@Observable
public final class ConnectionHealth {
    public static let shared = ConnectionHealth()

    public private(set) var snapshots: [MonitoredService: ServiceHealthSnapshot] = [:]
    /// Services whose host has an open breaker in the governor: shown down at once, without waiting for strikes.
    private var breakerOpen: Set<MonitoredService> = []

    private var consecutiveFailures: [MonitoredService: Int] = [:]
    /// Matches `QueueViewModel.unreachableThreshold`.
    static let downThreshold = 3

    public init() {}

    public func snapshot(for service: MonitoredService) -> ServiceHealthSnapshot {
        Self.merged(snapshots[service] ?? .unknown, breakerOpen: breakerOpen.contains(service))
    }

    /// Replace the set of services whose host breaker is open; traffic that closes a breaker clears it here too.
    func noteBreakers(_ open: Set<MonitoredService>) {
        guard open != breakerOpen else { return }
        breakerOpen = open
    }

    /// The worse of the recorded state and the governor's, but only while the breaker is open.
    nonisolated static func merged(_ recorded: ServiceHealthSnapshot, breakerOpen: Bool) -> ServiceHealthSnapshot {
        guard breakerOpen else { return recorded }
        if case .down = recorded.state { return recorded }
        return ServiceHealthSnapshot(state: .down(message: defaultDownMessage))
    }

    public func state(for service: MonitoredService) -> ConnectionHealthState {
        snapshot(for: service).state
    }

    /// A success goes `.ok` at once; failures keep the prior state until `downThreshold` strikes, so an
    /// unchecked service stays grey rather than flashing red.
    public func record(_ service: MonitoredService, success: Bool, detail: String?, message: String?) {
        if success {
            consecutiveFailures[service] = 0
            snapshots[service] = ServiceHealthSnapshot(state: .ok(detail: detail))
            return
        }
        let strikes = (consecutiveFailures[service] ?? 0) + 1
        consecutiveFailures[service] = strikes
        if strikes >= Self.downThreshold {
            snapshots[service] = ServiceHealthSnapshot(state: .down(message: message ?? Self.defaultDownMessage))
        }
    }

    /// Bypasses the debounce; a successful manual "Test Connection" is proof.
    public func forceOK(_ service: MonitoredService, detail: String?) {
        consecutiveFailures[service] = 0
        snapshots[service] = ServiceHealthSnapshot(state: .ok(detail: detail))
    }

    /// Bypasses the debounce; a failed "Test Connection" or queue action is concrete proof.
    public func forceDown(_ service: MonitoredService, message: String) {
        consecutiveFailures[service] = Self.downThreshold
        snapshots[service] = ServiceHealthSnapshot(state: .down(message: message.isEmpty ? Self.defaultDownMessage : message))
    }

    public func markUnknown(_ service: MonitoredService) {
        guard snapshots[service]?.state != .unknown || consecutiveFailures[service] != nil else { return }
        consecutiveFailures[service] = 0
        snapshots[service] = .unknown
    }

    nonisolated private static var defaultDownMessage: String {
        String(localized: "health.unreachable.label", bundle: .module)
    }
}
