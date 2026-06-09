import SwiftUI

struct PopoverEmptyState<MoreMenu: View>: View {
    let onOpenSettings: () -> Void
    @ViewBuilder var moreMenu: () -> MoreMenu

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 14) {
                Image(systemName: "gearshape.2")
                    .scaledFont(size: 28, weight: .light)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 4) {
                    Text("common.arrbarrIsNotConfigured.label", bundle: .module)
                        .font(.headline)
                    Text("common.connectRadarrSonarrOr.tooltip", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 6) {
                    emptyStep(number: 1, text: "Open your arr's web UI → Settings → General")
                    emptyStep(number: 2, text: "Copy the API Key")
                    emptyStep(number: 3, text: "Paste it here, along with the URL")
                }
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                Button { onOpenSettings() } label: { Text("Open Settings…", bundle: .module) }
                    .modifier(GlassProminentButtonStyle())
                    .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            moreMenu()
                .padding(8)
        }
    }

    private func emptyStep(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(number).")
                .scaledFont(size: 11, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(.tertiary)
            Text(text)
        }
    }
}
