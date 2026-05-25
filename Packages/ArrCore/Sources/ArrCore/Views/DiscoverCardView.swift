import SwiftUI

public struct DiscoverCardView: View {
    let item: DiscoverItem
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void

    public init(item: DiscoverItem,
                onSwipeRight: @escaping () -> Void,
                onSwipeLeft: @escaping () -> Void) {
        self.item = item
        self.onSwipeRight = onSwipeRight
        self.onSwipeLeft = onSwipeLeft
    }

    public var body: some View {
        VStack(spacing: 12) {
            poster
            titleBlock
            overview
            originChip
            actionRow
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var poster: some View {
        RemotePoster(url: item.result.posterURL, apiKey: nil)
            .frame(width: 160, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var titleBlock: some View {
        VStack(spacing: 2) {
            Text(item.result.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let y = item.result.year {
                Text(verbatim: "\(y)")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let text = item.result.overview, !text.isEmpty {
            Text(text)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
    }

    private var originChip: some View {
        HStack(spacing: 4) {
            Image(systemName: originIcon)
                .scaledFont(size: 10, weight: .semibold)
            Text(originLabel, bundle: .module)
                .scaledFont(size: 10, weight: .semibold)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private var originIcon: String {
        switch item.originLabel {
        case .tmdb:    return "film"
        case .library: return "books.vertical"
        case .llm:     return "sparkles"
        }
    }

    private var originLabel: LocalizedStringKey {
        switch item.originLabel {
        case .tmdb:    return "From TMDB"
        case .library: return "From your library"
        case .llm:     return "From AI"
        }
    }

    private var actionRow: some View {
        HStack(spacing: 24) {
            Button(action: onSwipeLeft) {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 32, weight: .regular)
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button(action: onSwipeRight) {
                Image(systemName: rightActionIcon)
                    .scaledFont(size: 32, weight: .regular)
                    .foregroundStyle(Color.green.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private var rightActionIcon: String {
        switch item.action {
        case .addToRadarr: return "plus.circle.fill"
        case .openDetail:  return "play.circle.fill"
        }
    }
}
