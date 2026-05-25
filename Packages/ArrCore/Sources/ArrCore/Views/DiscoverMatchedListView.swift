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
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ], spacing: 8) {
                    ForEach(items) { item in
                        PickCell(item: item, onAct: onAct, onRemove: onRemove)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
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
}

// MARK: - PickCell

private struct PickCell: View {
    let item: DiscoverItem
    let onAct: (DiscoverItem) -> Void
    let onRemove: (DiscoverItem) -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            RemotePoster(
                url: item.result.posterURL,
                apiKey: nil,
                size: CGSize(width: 110, height: 165),
                cornerRadius: 6
            )
            .aspectRatio(2.0/3.0, contentMode: .fit)

            if isHovering {
                hoverOverlay
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            // Source badge always visible top-left.
            sourceBadge
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
    }

    @ViewBuilder
    private var hoverOverlay: some View {
        ZStack {
            // Dark scrim so action icons are legible on any poster.
            Color.black.opacity(0.55)

            VStack(spacing: 4) {
                Text(item.result.title)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                if let y = item.result.year {
                    Text(verbatim: "\(y)")
                        .scaledFont(size: 10)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer().frame(height: 4)
                HStack(spacing: 14) {
                    Button {
                        onAct(item)
                    } label: {
                        Image(systemName: actionIcon)
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .help(Text(actionHelp, bundle: .module))

                    Button {
                        onRemove(item)
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.red.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .help(Text("Remove", bundle: .module))
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch item.originLabel {
        case .library:
            InLibraryBadge()
        case .tmdb:
            outlineBadge(text: "Discover", color: .blue)
        case .llm:
            outlineBadge(text: "AI", color: .purple)
        }
    }

    @ViewBuilder
    private func outlineBadge(text: String, color: Color) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .scaledFont(size: 8, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 0.75))
    }

    private var actionIcon: String {
        switch item.action {
        case .addToRadarr, .addToSonarr: return "plus"
        case .openDetail: return "play.fill"
        }
    }

    private var actionHelp: LocalizedStringKey {
        switch item.action {
        case .addToRadarr: return "Add to Radarr"
        case .addToSonarr: return "Add to Sonarr"
        case .openDetail:  return "Watch"
        }
    }
}
