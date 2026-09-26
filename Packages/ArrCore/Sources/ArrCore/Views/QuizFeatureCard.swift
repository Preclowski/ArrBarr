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

    /// Which pool the deck is drawn from. The button itself fires `.newToMe`
    /// — the everyday case, and the one the card's subtitle promises; the
    /// others hang off the chevron so the card stays a single decision until
    /// somebody wants a different one.
    public enum Variant: CaseIterable, Hashable, Sendable {
        /// Titles the library doesn't have (the tool's `library_mode: "new"`).
        case newToMe
        /// Rediscovery: the deck comes out of the shelf they already own.
        case inLibrary
        /// What is on right now — in cinemas, or airing this season.
        case rightNow
        /// Well-reviewed, off the beaten track. No canon, no blockbusters.
        case hiddenGems

        /// Menu label. Only `rightNow` needs to know the kind — "In cinemas"
        /// is nonsense for a series, and "Airing now" for a film.
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

        /// Catalog key of the chat message this variant sends. Resolved by the
        /// host in the in-app language (see `AppLocalized`), exactly like the
        /// plain CTA.
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
    /// The decks this setup can deal — `rightNow` needs TMDB's live listings.
    public let variants: [Variant]
    /// Poster URLs sampled from the user's library — render as a fanned deck
    /// on the left, telegraphing "swipe through *your* titles". Empty falls
    /// back to placeholder tiles so the layout is stable before posters load.
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
                        // Keep the wrapped height: squeezed for space (a short
                        // panel, the keyboard up) SwiftUI would rather truncate
                        // this to one line than let the layout drop a
                        // suggestion row, and a cut-off sentence is the worse
                        // way to save 16pt.
                        .fixedSize(horizontal: false, vertical: true)
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

    /// Split control: the label starts the everyday quiz, the chevron opens the
    /// other decks. One capsule, one hairline — two buttons side by side would
    /// read as two separate decisions.
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
            // `.button` + `.plain`, never `.borderlessButton`: that one
            // re-renders the label with its own metrics and tint, and the
            // chevron came out bigger and greyer than the label beside it.
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
