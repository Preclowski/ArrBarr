import SwiftUI

private var platformControlBackground: Color {
    #if os(macOS)
    Color(NSColor.controlBackgroundColor)
    #else
    Color(.systemBackground)
    #endif
}

/// Hero card on the chat empty state. Single point of gravity:
/// icon + title + one-line subtitle + dark full-width CTA pill.
///
/// Lavender card background uses semantic colors so it adapts to the
/// system appearance — `NSColor.controlBackgroundColor` for the body
/// + a small accent tint overlay. The icon keeps the purple gradient
/// as the single chromatic accent on the chat surface.
public struct QuizFeatureCard: View {
    /// A quiz session is single-kind (the `discover_in_quiz` tool takes one
    /// `kind`). Letting the user pick here keeps the model from firing two
    /// separate sessions when the prompt says "movies and shows".
    public enum Kind { case movies, series }

    public let onStart: (Kind) -> Void
    /// Poster URLs sampled from the user's library — render as a fanned deck
    /// on the left, telegraphing "swipe through *your* titles". Empty falls
    /// back to placeholder tiles so the layout is stable before posters load.
    public let posterURLs: [URL]

    public init(posterURLs: [URL] = [], onStart: @escaping (Kind) -> Void) {
        self.posterURLs = posterURLs
        self.onStart = onStart
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                deck

                VStack(alignment: .leading, spacing: 4) {
                    Text("onboarding.quiz.button", bundle: .module)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("onboarding.swipeThroughPicksAdd.tooltip", bundle: .module)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            // Pick a single kind — Movies or Series — so the quiz opens one
            // deck instead of the model spawning a movie session *and* a
            // series session.
            HStack(spacing: 8) {
                ctaButton(.movies, labelKey: "chat.empty.quiz.cta.movies", symbol: "film")
                ctaButton(.series, labelKey: "chat.empty.quiz.cta.series", symbol: "tv")
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(platformControlBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func ctaButton(_ kind: Kind, labelKey: LocalizedStringKey, symbol: String) -> some View {
        Button { onStart(kind) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(labelKey, bundle: .module)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(platformControlBackground)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.filterPill + 2, style: .continuous)
                    .fill(Color.primary.opacity(0.9))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fanned poster deck

    private static let posterSize = CGSize(width: 40, height: 60)

    /// Up to three posters fanned like the in-chat Quiz resume card, so the
    /// empty-state card and the resume card read as the same feature.
    @ViewBuilder
    private var deck: some View {
        let visible = Array(posterURLs.prefix(3))
        ZStack(alignment: .leading) {
            if visible.isEmpty {
                ForEach(0..<3, id: \.self) { idx in
                    placeholderCard(index: idx)
                }
            } else {
                ForEach(Array(visible.enumerated().reversed()), id: \.offset) { idx, url in
                    posterCard(url: url, index: idx)
                }
            }
        }
        .frame(width: Self.posterSize.width + 2 * 16, height: Self.posterSize.height, alignment: .leading)
    }

    private func deckTransform(_ index: Int) -> (x: CGFloat, rotation: Double) {
        (CGFloat(index) * 16, [(-4.0), 2.0, 5.0][min(index, 2)])
    }

    @ViewBuilder
    private func posterCard(url: URL, index: Int) -> some View {
        let t = deckTransform(index)
        RemotePoster(
            url: url,
            apiKey: nil,
            tier: .icon,
            size: Self.posterSize,
            cornerRadius: 4,
            fallbackSymbol: "film",
            showsLoadingIndicator: true
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .rotationEffect(.degrees(t.rotation))
        .offset(x: t.x)
    }

    @ViewBuilder
    private func placeholderCard(index: Int) -> some View {
        let t = deckTransform(index)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LinearGradient(
                colors: [
                    Color(red: 122/255, green: 90/255, blue: 248/255),
                    Color(red: 79/255, green: 70/255, blue: 229/255),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: Self.posterSize.width, height: Self.posterSize.height)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(index == 0 ? 0.9 : 0.4))
            )
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .rotationEffect(.degrees(t.rotation))
            .offset(x: t.x)
    }
}
