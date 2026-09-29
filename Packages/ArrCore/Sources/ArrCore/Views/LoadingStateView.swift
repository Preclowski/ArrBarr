import SwiftUI

/// The empty-surface loading state: the system spinner, over a "Loading…" line
/// when there is room for one.
struct LoadingStateView: View {
    var label: LocalizedStringKey? = "queue.loading.button"

    var body: some View {
        if let label {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(label, bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}
