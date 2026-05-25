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
        Button {
            onAct(item)
        } label: {
            HStack(spacing: 10) {
                RemotePoster(
                    url: item.result.posterURL,
                    apiKey: nil,
                    size: CGSize(width: 36, height: 54),
                    cornerRadius: 4
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.result.title)
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let y = item.result.year {
                            Text(verbatim: "(\(y))")
                                .scaledFont(size: 12)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !metadataLine(for: item).isEmpty {
                        Text(metadataLine(for: item))
                            .scaledFont(size: 11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    onRemove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Remove", bundle: .module))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func metadataLine(for item: DiscoverItem) -> String {
        let segments: [String] = [
            item.result.runtime.flatMap { $0 > 0 ? "\($0) min" : nil },
            item.result.imdb.map { String(format: "IMDb %.1f", $0) },
            item.result.genres.first,
        ].compactMap { $0 }
        return segments.joined(separator: " · ")
    }
}
