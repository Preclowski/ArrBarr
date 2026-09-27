import SwiftUI

private var platformControlBackground: Color {
    #if os(macOS)
    Color(NSColor.controlBackgroundColor)
    #else
    Color(.systemBackground)
    #endif
}

/// Hero card on the chat empty state.
public struct QuizFeatureCard: View {
    /// `discover_in_quiz` takes one `kind`; picking here stops the model firing two sessions for "movies and shows".
    public enum Kind { case movies, series }

    /// The button fires `.newToMe`; the other decks hang off the chevron.
    public enum Variant: CaseIterable, Hashable, Sendable {
        /// Titles the library doesn't have (`library_mode: "new"`).
        case newToMe
        case inLibrary
        case rightNow
        case hiddenGems

        /// Only `rightNow` depends on kind: "In cinemas" vs "Airing now".
        public func labelKey(for kind: Kind) -> LocalizedStringKey {
            switch self {
            case .newToMe:    return "quiz.variant.newToMe.button"
            case .inLibrary:  return "quiz.variant.inLibrary.button"
            case .hiddenGems: return "quiz.variant.hiddenGems.button"
            case .rightNow:
                return kind == .movies ? "quiz.variant.inCinemas.button"
                                       : "quiz.variant.airingNow.button"
            }
        }

        /// Resolved by the host in the in-app language (see `AppLocalized`).
        public func promptKey(for kind: Kind) -> String {
            let media = kind == .movies ? "movies" : "series"
            switch self {
            case .newToMe:    return "chat.quizPrompt.\(media)"
            case .inLibrary:  return "chat.quizPrompt.\(media).inLibrary"
            case .rightNow:   return "chat.quizPrompt.\(media).rightNow"
            case .hiddenGems: return "chat.quizPrompt.\(media).hiddenGems"
            }
        }

        func symbol(for kind: Kind) -> String {
            switch self {
            case .newToMe:    return "sparkles"
            case .inLibrary:  return "books.vertical"
            case .hiddenGems: return "diamond"
            case .rightNow:   return kind == .movies ? "ticket" : "antenna.radiowaves.left.and.right"
            }
        }
    }

    public let onStart: (Kind, Variant) -> Void
    /// `rightNow` needs TMDB's live listings.
    public let variants: [Variant]
    /// Empty falls back to placeholder tiles so the layout is stable before posters load.
    public let posterURLs: [URL]

    public init(posterURLs: [URL] = [], variants: [Variant] = Variant.allCases,
                onStart: @escaping (Kind, Variant) -> Void) {
        self.posterURLs = posterURLs
        self.variants = variants
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
                        // Squeezed for space, SwiftUI would truncate this to one line rather than drop a suggestion row.
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

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

    /// One capsule with a hairline: two separate buttons would read as two decisions.
    @ViewBuilder
    private func ctaButton(_ kind: Kind, labelKey: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 0) {
            Button { onStart(kind, .newToMe) } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                    Text(labelKey, bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(platformControlBackground.opacity(0.22))
                .frame(width: 1, height: 18)

            Menu {
                ForEach(variants, id: \.self) { variant in
                    Button { onStart(kind, variant) } label: {
                        Label {
                            Text(variant.labelKey(for: kind), bundle: .module)
                        } icon: {
                            Image(systemName: variant.symbol(for: kind))
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 32)
                    .contentShape(Rectangle())
            }
            // `.button` + `.plain`, never `.borderlessButton`, which re-renders the label with its own metrics and tint.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(Text("quiz.variant.more.label", bundle: .module))
        }
        .foregroundStyle(platformControlBackground)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.filterPill + 2, style: .continuous)
                .fill(Color.primary.opacity(0.9))
        )
    }

    // MARK: - Fanned poster deck

    private static let posterSize = CGSize(width: 40, height: 60)

    /// Fanned like `QuizResumeCard` so both read as the same feature.
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
