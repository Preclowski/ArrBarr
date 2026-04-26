import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var viewModel: QueueViewModel
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    QueueSectionView(
                        title: "Sonarr",
                        symbol: "tv",
                        items: viewModel.sonarr,
                        viewModel: viewModel
                    )

                    Divider().padding(.horizontal, 12)

                    QueueSectionView(
                        title: "Radarr",
                        symbol: "film",
                        items: viewModel.radarr,
                        viewModel: viewModel
                    )
                }
                .padding(.vertical, 12)
            }

            footer
        }
        .frame(width: 400, height: 480)
        .background(.ultraThinMaterial)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let err = viewModel.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
            Divider()
            HStack(spacing: 8) {
                Button(action: { Task { await viewModel.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")

                Spacer()

                Button("Settings…", action: onOpenSettings)
                    .buttonStyle(.borderless)
                Button("Quit", action: onQuit)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
