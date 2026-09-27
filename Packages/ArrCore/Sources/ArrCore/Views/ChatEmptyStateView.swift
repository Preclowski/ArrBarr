import SwiftUI

/// Chat tab empty state: greeting, Quiz hero card and suggestion prompts.
struct ChatEmptyStateView: View {
    let onQuizStart: (QuizFeatureCard.Kind, QuizFeatureCard.Variant) -> Void
    let onSuggestionTap: (String) -> Void
    /// Empty renders placeholders.
    let quizPosterURLs: [URL]
    let quizVariants: [QuizFeatureCard.Variant]
    /// The sent prompt must be resolved in the in-app locale, or it lags in the
    /// process language until relaunch.
    var locale: Locale = .current

    /// One catalog key per suggestion, localized for both the chip and the sent prompt.
    @State private var carousel = SuggestionCarousel(window: maxSuggestions)

    private static let maxSuggestions = 5
    private static let rotationStep = Duration.seconds(1)

    @State private var shownCount = maxSuggestions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        quizPosterURLs: [URL] = [],
        quizVariants: [QuizFeatureCard.Variant] = QuizFeatureCard.Variant.allCases,
        locale: Locale = .current,
        onQuizStart: @escaping (QuizFeatureCard.Kind, QuizFeatureCard.Variant) -> Void,
        onSuggestionTap: @escaping (String) -> Void
    ) {
        self.quizPosterURLs = quizPosterURLs
        self.quizVariants = quizVariants
        self.locale = locale
        self.onQuizStart = onQuizStart
        self.onSuggestionTap = onSuggestionTap
    }

    var body: some View {
        // No scrolling: `ViewThatFits` drops the suggestions that don't fit instead.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("chat.whatToWatchTonight.tooltip", bundle: .module)
                    .font(.system(size: 22, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("chat.empty.subtitle", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)

            QuizFeatureCard(posterURLs: quizPosterURLs, variants: quizVariants, onStart: onQuizStart)
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

    /// Measured, not arithmetic: a wrapped two-line row counts double.
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
        let count = min(count, carousel.visible.count)
        return VStack(spacing: 10) {
            // Keyed by slot: keyed by suggestion, each rotation slid a whole row in.
            ForEach(0..<count, id: \.self) { slot in
                let key = carousel.visible[slot]
                SuggestionPromptRow(key) {
                    // Env-locale label, so resolve explicitly; the process language lags until relaunch.
                    onSuggestionTap(AppLocalized.string(key, locale: locale))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        // Rotation needs the placed count, or a beat lands on an invisible row.
        .onAppear { shownCount = count }
    }

    /// Lives in a `task`, so it stops with the empty state.
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

