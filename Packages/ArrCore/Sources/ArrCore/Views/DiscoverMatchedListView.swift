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
        HStack(spacing: 10) {
            RemotePoster(url: item.result.posterURL, apiKey: nil)
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.result.title)
                    .scaledFont(size: 13, weight: .semibold)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let y = item.result.year {
                        Text(verbatim: "\(y)")
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    originBadge(item.originLabel)
                }
            }
            Spacer()

            Button {
                onAct(item)
            } label: {
                Image(systemName: actionIcon(item.action))
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(Text(actionHelp(item.action), bundle: .module))

            Button {
                onRemove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 14)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(Text("Remove", bundle: .module))
        }
        .padding(.vertical, 4)
    }

    private func originBadge(_ origin: DiscoverItem.Origin) -> some View {
        let label: LocalizedStringKey
        let icon: String
        switch origin {
        case .tmdb:    label = "From TMDB";          icon = "film"
        case .library: label = "From your library";  icon = "books.vertical"
        case .llm:     label = "From AI";            icon = "sparkles"
        }
        return HStack(spacing: 3) {
            Image(systemName: icon).scaledFont(size: 9)
            Text(label, bundle: .module).scaledFont(size: 10)
        }
        .foregroundStyle(.tertiary)
    }

    private func actionIcon(_ action: DiscoverAction) -> String {
        switch action {
        case .addToRadarr: return "plus.circle.fill"
        case .openDetail:  return "play.circle.fill"
        }
    }
    private func actionHelp(_ action: DiscoverAction) -> LocalizedStringKey {
        switch action {
        case .addToRadarr: return "Add to Radarr"
        case .openDetail:  return "Watch"
        }
    }
}
