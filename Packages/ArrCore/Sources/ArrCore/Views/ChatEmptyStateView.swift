import SwiftUI

/// Chat tab empty state: greeting + hero Quiz card + suggestion prompts.
/// Replaces the previous inline list of 6 capsule pills with a clearer
/// information hierarchy (one hero point of gravity, then optional
/// quick-prompts under a hairline divider).
///
/// Suggestion taps fire `onSuggestionTap(prompt)` with the *visible*
/// prompt string — same effect as the user typing and hitting return.
/// `onQuizStart` is the hero CTA; the parent decides what that
/// translates to (today: synthesised chat message that triggers the
/// `discover_in_quiz` tool).
public struct ChatEmptyStateView: View {
    public let onQuizStart: (QuizFeatureCard.Kind, QuizFeatureCard.Variant) -> Void
    public let onSuggestionTap: (String) -> Void
    /// Poster URLs for the Quiz card deck — sampled from the user's library
    /// by the parent (see `LibraryPosterSampler`). Empty renders placeholders.
    public let quizPosterURLs: [URL]
    /// In-app language, so the prompt SENT for a tapped suggestion matches its
    /// visible chip after a live language switch. The chip label follows
    /// `environment(\.locale)`; the sent string must be resolved explicitly
    /// (see `AppLocalized`) or it lags in the process language until relaunch.
    public var locale: Locale = .current

    /// A chat suggestion is one catalog key: it's localized both for the chip
    /// label AND for the prompt actually sent to the LLM — so tapping an English
    /// chip sends an English question, a Polish chip a Polish one, etc. The
    /// shortlist and its rules live in `SuggestionCarousel`.
    @State private var carousel = SuggestionCarousel(window: maxSuggestions)

    /// The most rows the layout will ever try to place; `suggestions` drops as
    /// many as the surface can't take.
    private static let maxSuggestions = 5
    /// One row changes, and a second later the next one does. Fast enough that
    /// the list reads as alive, slow enough to finish reading the row you were
    /// looking at.
    private static let rotationStep = Duration.seconds(1)

    /// How many rows the fitted layout actually placed (see `suggestions`).
    @State private var shownCount = maxSuggestions
    /// Rotation is motion for its own sake; anyone who has asked the system to
    /// stop that gets a still list.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        quizPosterURLs: [URL] = [],
        locale: Locale = .current,
        onQuizStart: @escaping (QuizFeatureCard.Kind, QuizFeatureCard.Variant) -> Void,
        onSuggestionTap: @escaping (String) -> Void
    ) {
        self.quizPosterURLs = quizPosterURLs
        self.locale = locale
        self.onQuizStart = onQuizStart
        self.onSuggestionTap = onSuggestionTap
    }

    public var body: some View {
        // Nothing here scrolls: the surface is a fixed panel, and a scroll bar
        // under a five-item list reads as a mistake. What gives instead is the
        // number of suggestions — `ViewThatFits` drops the ones there is no
        // room for (see `suggestions`), so a short panel shows three and a tall
        // one shows five, and neither has anything hidden below an edge.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("chat.whatToWatchTonight.tooltip", bundle: .module)
                    .font(.system(size: 22, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("chat.quizATipOr.tooltip", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)

            QuizFeatureCard(posterURLs: quizPosterURLs, onStart: onQuizStart)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            HStack(spacing: 12) {
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
                Text("chat.orAsk.button", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            suggestions

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await rotate() }
    }

    /// As many suggestions as the panel can actually show. The candidates are
    /// measured for real, so a wrapped two-line row in German counts double
    /// exactly as it should — which is why this isn't arithmetic over an
    /// assumed row height.
    @ViewBuilder
    private var suggestions: some View {
        ViewThatFits(in: .vertical) {
            suggestionStack(Self.maxSuggestions)
            suggestionStack(4)
            suggestionStack(3)
            suggestionStack(2)
            suggestionStack(1)
        }
    }

    private func suggestionStack(_ count: Int) -> some View {
        VStack(spacing: 10) {
            ForEach(carousel.visible.prefix(count), id: \.self) { key in
                SuggestionPromptRow(LocalizedStringKey(key)) {
                    // Send the prompt in the in-app language so it
                    // matches the chip's (env-locale) label — not the
                    // process language, which lags until relaunch.
                    onSuggestionTap(AppLocalized.string(key, locale: locale))
                }
                // Keyed by the suggestion, so a slot that changes is an
                // insertion and a removal SwiftUI can cross-fade —
                // without it the row is "the same view with new text"
                // and the label just pops.
                .id(key)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        // Only the candidate that fits is ever placed, so this is the honest
        // answer to "how many are on screen" — and the rotation needs it, or a
        // beat lands on a row nobody can see.
        .onAppear { shownCount = count }
    }

    /// Walks the list, one row per `rotationStep`. Lives in a `task`, so it
    /// stops the moment the empty state does — a first message, a tab switch,
    /// the panel closing.
    private func rotate() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.rotationStep)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.45)) {
                carousel.advance(within: shownCount)
            }
        }
    }
}

