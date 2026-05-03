import SwiftUI

struct QueueSectionView: View {
    let title: String
    let symbol: String
    let entries: [QueueRowEntry]
    var error: String?
    var health: [ArrHealthRecord] = []
    var isCollapsed: Bool = false
    var onToggleCollapse: (() -> Void)? = nil
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    var onShowHistory: (() -> Void)? = nil
    @State private var hoveringHistory = false

    /// Total individual queue items represented by this section's entries.
    /// Singletons count as 1; groups contribute their member count.
    private var itemCount: Int {
        entries.reduce(0) { sum, entry in
            switch entry {
            case .single: return sum + 1
            case .group(let g): return sum + g.memberCount
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if onToggleCollapse != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 10)
                }
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if error == nil {
                    Text("\(itemCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if !health.isEmpty { healthBadge }
                }
                Spacer()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(error)
                } else if let onShowHistory {
                    Button(action: onShowHistory) {
                        HStack(spacing: 2) {
                            Text("Show history")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(hoveringHistory ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringHistory = $0 }
                    .localizedHelp("Show history", locale: configStore.currentLocale)
                }
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture { onToggleCollapse?() }

            if !isCollapsed && error == nil {
                if entries.isEmpty {
                    Text("Queue empty")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 2) {
                        ForEach(entries) { entry in
                            row(for: entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: QueueRowEntry) -> some View {
        switch entry {
        case .single(let item):
            QueueRowView(
                item: item,
                onPause: { [weak viewModel] in Task { await viewModel?.pause(item) } },
                onResume: { [weak viewModel] in Task { await viewModel?.resume(item) } },
                onDelete: { [weak viewModel] in Task { await viewModel?.delete(item) } }
            )
        case .group(let group):
            // All members share a downloadId so calling the action on the
            // representative is enough — the arr's queue API affects the
            // whole physical download.
            let rep = group.representative
            QueueGroupRowView(
                group: group,
                onPause:  { [weak viewModel] in Task { await viewModel?.pause(rep) } },
                onResume: { [weak viewModel] in Task { await viewModel?.resume(rep) } },
                onDelete: { [weak viewModel] in Task { await viewModel?.delete(rep) } }
            )
        }
    }

    private var healthBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.orange)
            .help(health.compactMap(\.message).joined(separator: "\n"))
    }
}
