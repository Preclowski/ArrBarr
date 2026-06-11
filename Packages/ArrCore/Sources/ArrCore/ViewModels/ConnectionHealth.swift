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
@MainActor
@Observable
public final class ConnectionHealth {
    public static let shared = ConnectionHealth()

    public private(set) var snapshots: [MonitoredService: ServiceHealthSnapshot] = [:]

    private var consecutiveFailures: [MonitoredService: Int] = [:]
    /// Consecutive failed checks before a service flips to `.down`. Matches
    /// `QueueViewModel.unreachableThreshold`.
    static let downThreshold = 3

    public init() {}

    public func snapshot(for service: MonitoredService) -> ServiceHealthSnapshot {
        snapshots[service] ?? .unknown
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
            snapshots[service] = ServiceHealthSnapshot(state: .ok(detail: detail), lastChecked: Date())
            return
        }
        let strikes = (consecutiveFailures[service] ?? 0) + 1
        consecutiveFailures[service] = strikes
        if strikes >= Self.downThreshold {
            snapshots[service] = ServiceHealthSnapshot(
                state: .down(message: message ?? Self.defaultDownMessage),
                lastChecked: Date()
            )
        } else {
            // Keep the prior visible state; just stamp the check time.
            let prior = snapshots[service]?.state ?? .unknown
            snapshots[service] = ServiceHealthSnapshot(state: prior, lastChecked: Date())
        }
    }

    /// Pin a service `.ok` immediately, bypassing the debounce. Used by a
    /// successful manual "Test Connection".
    public func forceOK(_ service: MonitoredService, detail: String?) {
        consecutiveFailures[service] = 0
        snapshots[service] = ServiceHealthSnapshot(state: .ok(detail: detail), lastChecked: Date())
    }

    /// Pin a service `.down` immediately, bypassing the debounce. Used by a
    /// failed manual "Test Connection" and by a failed queue action (a concrete
    /// proof the client is unreachable / misconfigured).
    public func forceDown(_ service: MonitoredService, message: String) {
        consecutiveFailures[service] = Self.downThreshold
        snapshots[service] = ServiceHealthSnapshot(
            state: .down(message: message.isEmpty ? Self.defaultDownMessage : message),
            lastChecked: Date()
        )
    }

    /// A service that's no longer configured → drop back to grey and clear
    /// strikes, so a stale red/green doesn't linger after the user removes it.
    public func markUnknown(_ service: MonitoredService) {
        guard snapshots[service]?.state != .unknown || consecutiveFailures[service] != nil else { return }
        consecutiveFailures[service] = 0
        snapshots[service] = .unknown
    }

    private static var defaultDownMessage: String {
        String(localized: "health.unreachable.label", bundle: .module)
    }
}
