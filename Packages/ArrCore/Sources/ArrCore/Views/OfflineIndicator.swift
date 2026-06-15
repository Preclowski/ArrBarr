import SwiftUI

/// A deliberately quiet "you've left the home network" chip.
///
/// ArrBarr talks to arr servers on the user's LAN, so checking the queue from
/// out of the house (no VPN) is an *expected*, recurring state — not an error.
/// The indicator is therefore a small secondary-tinted pill, never an alarm:
/// a `network.slash` glyph + a lowercase "offline" label. Tapping it triggers a
/// manual refresh; hovering (macOS) reveals how stale the shown data is.
///
/// It renders nothing on its own — callers gate visibility on
/// `viewModel.isFullyOffline` so the chip simply isn't in the layout when the
/// stack is reachable.
public struct OfflineIndicator: View {
    var viewModel: QueueViewModel

    public init(viewModel: QueueViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Button {
            Task { await viewModel.refresh() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "network.slash")
                    .scaledFont(size: 10, weight: .semibold)
                Text("offline.indicator.label", bundle: .module)
                    .scaledFont(size: 11)
                    .textCase(.lowercase)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: helpText))
        .accessibilityLabel(Text(verbatim: helpText))
    }

    /// Hover tooltip / VoiceOver text: "Offline — last updated 2 minutes ago",
    /// or just the bare label before the first successful fetch.
    private var helpText: String {
        guard let date = viewModel.lastSuccessfulRefresh else {
            return String(localized: "offline.indicator.label", bundle: .module)
        }
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        return String(
            format: String(localized: "offline.indicator.tooltip", bundle: .module),
            relative
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

// MARK: - Environment

private struct QueueOfflineKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// True when the whole arr stack is unreachable (see
    /// `QueueViewModel.isFullyOffline`). Queue rows read this to hide the
    /// mutating controls (pause / resume / delete) that can't succeed without
    /// a live LAN connection, so the user isn't offered actions that will fail.
    var queueOffline: Bool {
        get { self[QueueOfflineKey.self] }
        set { self[QueueOfflineKey.self] = newValue }
    }
}
