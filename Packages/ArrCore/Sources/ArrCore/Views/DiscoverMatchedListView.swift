import SwiftUI

public struct DiscoverMatchedListView: View {
    let items: [DiscoverItem]
    let onAct: (DiscoverItem) -> Void
    let onRemove: (DiscoverItem) -> Void
    let onKeepPlaying: () -> Void

    public init(items: [DiscoverItem],
                onAct: @escaping (DiscoverItem) -> Void,
                onRemove: @escaping (DiscoverItem) -> Void,
                onKeepPlaying: @escaping () -> Void) {
        self.items = items
        self.onAct = onAct
        self.onRemove = onRemove
        self.onKeepPlaying = onKeepPlaying
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
    }

    private var header: some View {
        HStack {
            Text("Your picks", bundle: .module)
                .scaledFont(size: 13, weight: .semibold)
            Spacer()
            Button(action: onKeepPlaying) {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack.fill")
                        .scaledFont(size: 11, weight: .semibold)
                    Text("Keep playing", bundle: .module)
                        .scaledFont(size: 11, weight: .semibold)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        HStack(spacing: 6) {
            SearchResultRow(result: item.result, onTap: { onAct(item) })
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onRemove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 13)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help(Text("Remove", bundle: .module))
        }
    }
}
