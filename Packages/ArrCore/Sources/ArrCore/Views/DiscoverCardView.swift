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
        VStack(spacing: 10) {
            card                 // .frame(maxHeight: .infinity) — eats remaining space
            actionRow            // intrinsic height, ~36pt
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Poster fills the available rectangle (any aspect), with title/year/
    /// overview overlaid on a bottom gradient and origin chip top-left.
    private var card: some View {
        ZStack(alignment: .bottomLeading) {
            RemotePoster(url: item.result.posterURL, apiKey: nil, fill: true)

            // Bottom gradient for text legibility — covers ~45% of height.
            LinearGradient(
                colors: [.black.opacity(0.9), .black.opacity(0.0)],
                startPoint: .bottom, endPoint: .top
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            // Top-left origin chip on a glass shield.
            originChip
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.result.title)
                    .scaledFont(size: 18, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let y = item.result.year {
                    Text(verbatim: "\(y)")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(.white.opacity(0.85))
                }
                if let overview = item.result.overview, !overview.isEmpty {
                    Text(overview)
                        .scaledFont(size: 11)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
    }

    private var originChip: some View {
        HStack(spacing: 4) {
            Image(systemName: originIcon)
                .scaledFont(size: 10, weight: .semibold)
            Text(originLabel, bundle: .module)
                .scaledFont(size: 10, weight: .semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.ultraThinMaterial))
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

    /// DetailView-style CTAs. Bare Button + label HStack, GlassProminent,
    /// `.tint` for skip = red, accent for primary. No `.controlSize(.large)`.
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: onSwipeLeft) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 11, weight: .semibold)
                    Text("Skip", bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .modifier(GlassProminentButtonStyle())
            .tint(.red)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button(action: onSwipeRight) {
                HStack(spacing: 6) {
                    Image(systemName: rightIcon)
                        .scaledFont(size: 11, weight: .semibold)
                    Text(rightLabel, bundle: .module)
                        .scaledFont(size: 12, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .modifier(GlassProminentButtonStyle())
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private var rightIcon: String {
        switch item.action {
        case .addToRadarr: return "plus"
        case .openDetail:  return "play.fill"
        }
    }
    private var rightLabel: LocalizedStringKey {
        switch item.action {
        case .addToRadarr: return "Add to Radarr"
        case .openDetail:  return "Watch"
        }
    }
}
