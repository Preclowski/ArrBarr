import SwiftUI

/// A deliberately quiet "you've left the home network" chip: being away from the
/// LAN is expected, not an error. Callers gate it on `viewModel.isFullyOffline`.
struct OfflineIndicator: View {
    var viewModel: QueueViewModel

    init(viewModel: QueueViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
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

public extension EnvironmentValues {
    /// Rows hide their mutating controls, which can't succeed without the LAN.
    @Entry var queueOffline: Bool = false
    /// The row's delete animation is playing; the poster shows a trash mark.
    @Entry var queueRowLeaving: Bool = false
}
