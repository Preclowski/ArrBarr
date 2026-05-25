import SwiftUI

public struct DiscoverMatchedListView: View {
    let items: [DiscoverItem]
    let onAct: (DiscoverItem) -> Void
    let onRemove: (DiscoverItem) -> Void

    public init(items: [DiscoverItem],
                onAct: @escaping (DiscoverItem) -> Void,
                onRemove: @escaping (DiscoverItem) -> Void) {
        self.items = items
        self.onAct = onAct
        self.onRemove = onRemove
    }

    public var body: some View {
        if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .scaledFont(size: 22, weight: .light)
                .foregroundStyle(.tertiary)
            Text("No picks yet — swipe right to collect", bundle: .module)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func row(_ item: DiscoverItem) -> some View {
        HStack(spacing: 0) {
            SearchResultRow(result: item.result, onTap: { onAct(item) })
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onRemove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 13)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Remove", bundle: .module))
        }
    }
}
