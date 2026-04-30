import SwiftUI

struct QueueSectionView: View {
    let title: String
    let symbol: String
    let items: [QueueItem]
    var error: String?
    var health: [ArrHealthRecord] = []
    var isCollapsed: Bool = false
    var onToggleCollapse: (() -> Void)? = nil
    @ObservedObject var viewModel: QueueViewModel
    @EnvironmentObject var configStore: ConfigStore
    var onShowHistory: (() -> Void)? = nil
    @State private var hoveringHistory = false

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
                    Text("\(items.count)")
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
                if items.isEmpty {
                    Text("Queue empty")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            QueueRowView(item: item, viewModel: viewModel)
                        }
                    }
                }
            }
        }
    }

    private var healthBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.orange)
            .help(health.compactMap(\.message).joined(separator: "\n"))
    }
}
