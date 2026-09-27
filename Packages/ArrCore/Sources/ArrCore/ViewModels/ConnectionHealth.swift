import Foundation
import SwiftUI

/// Canonical, app-wide connection-health state for every monitored service.
///
/// Observed by both Settings (the per-service status dot) and the popover
/// (the "Needs you" rows for download-client / AI failures). Fed by
/// `QueueViewModel`: arr health comes from the live queue fetch, download-client
/// and AI health from `ConnectionHealthMonitor` probes, and manual "Test
/// Connection" / failed queue actions pin a result instantly.
///
/// Failures are debounced (`downThreshold` consecutive strikes) so a single
/// transient blip never flips a service red — the same ride-out-blips policy
/// `QueueViewModel.unreachableArrs` uses. A configured-but-not-yet-confirmed
/// service stays `.unknown` (grey), never green.
@Observable
public final class ConnectionHealth {
    public static let shared = ConnectionHealth()

    public private(set) var snapshots: [MonitoredService: ServiceHealthSnapshot] = [:]
    /// Services whose host has an open breaker in the governor: shown down at once, without waiting for strikes.
    private var breakerOpen: Set<MonitoredService> = []

    private var consecutiveFailures: [MonitoredService: Int] = [:]
    /// Consecutive failed checks before a service flips to `.down`. Matches
    /// `QueueViewModel.unreachableThreshold`.
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

    /// Record one debounced healthcheck outcome. A success resets the strike
    /// counter and goes `.ok` immediately; a failure increments and only flips
    /// to `.down` once `downThreshold` strikes accumulate — until then the prior
    /// state is kept (so a healthy service rides out a blip, and an unchecked
    /// one stays grey rather than flashing red).
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

    /// Pin a service `.ok` immediately, bypassing the debounce. Used by a
    /// successful manual "Test Connection".
    public func forceOK(_ service: MonitoredService, detail: String?) {
        consecutiveFailures[service] = 0
        snapshots[service] = ServiceHealthSnapshot(state: .ok(detail: detail))
    }

    /// Pin a service `.down` immediately, bypassing the debounce. Used by a
    /// failed manual "Test Connection" and by a failed queue action (a concrete
    /// proof the client is unreachable / misconfigured).
    public func forceDown(_ service: MonitoredService, message: String) {
        consecutiveFailures[service] = Self.downThreshold
        snapshots[service] = ServiceHealthSnapshot(state: .down(message: message.isEmpty ? Self.defaultDownMessage : message))
    }

    /// A service that's no longer configured → drop back to grey and clear
    /// strikes, so a stale red/green doesn't linger after the user removes it.
    public func markUnknown(_ service: MonitoredService) {
        guard snapshots[service]?.state != .unknown || consecutiveFailures[service] != nil else { return }
        consecutiveFailures[service] = 0
        snapshots[service] = .unknown
    }

    nonisolated private static var defaultDownMessage: String {
        String(localized: "health.unreachable.label", bundle: .module)
    }
}
