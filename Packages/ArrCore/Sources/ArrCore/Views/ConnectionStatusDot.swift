import SwiftUI

/// Persistent connection-health dot shown next to a service in Settings.
/// Green = last healthcheck passed, red = failing, grey = not checked yet
/// (never green merely because the service is configured). Driven by the
/// shared `ConnectionHealth` state, so it updates live as probes land.
struct ConnectionStatusDot: View {
    let service: MonitoredService

    var body: some View {
        let snapshot = ConnectionHealth.shared.snapshot(for: service)
        Circle()
            .fill(color(for: snapshot.state))
            .frame(width: 8, height: 8)
            .help(Text(verbatim: tooltip(for: snapshot.state)))
            .accessibilityLabel(Text(
                String(
                    format: String(localized: "health.status.accessibility", bundle: .module),
                    service.displayName,
                    stateLabel(for: snapshot.state)
                )
            ))
    }

    private func color(for state: ConnectionHealthState) -> Color {
        switch state {
        case .ok: return .green
        case .down: return .red
        case .unknown: return .secondary
        }
    }

    private func tooltip(for state: ConnectionHealthState) -> String {
        switch state {
        case .ok(let detail):
            return detail ?? String(localized: "health.connected.label", bundle: .module)
        case .down(let message):
            return message
        case .unknown:
            return String(localized: "health.unknown.label", bundle: .module)
        }
    }

    private func stateLabel(for state: ConnectionHealthState) -> String {
        switch state {
        case .ok: return String(localized: "health.connected.label", bundle: .module)
        case .down: return String(localized: "health.unreachable.label", bundle: .module)
        case .unknown: return String(localized: "health.unknown.label", bundle: .module)
        }
    }
}
