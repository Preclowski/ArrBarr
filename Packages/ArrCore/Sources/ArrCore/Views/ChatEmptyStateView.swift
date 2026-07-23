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
    public let onQuizStart: (QuizFeatureCard.Kind) -> Void
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
    /// chip sends an English question, a Polish chip a Polish one, etc.
    private let suggestionKeys: [String] = [
        "chat.empty.suggest.upcoming",
        "chat.empty.suggest.queue",
        "chat.empty.suggest.tasteMrRobot",
        "chat.empty.suggest.personSwinton",
    ]

    public init(
        quizPosterURLs: [URL] = [],
        locale: Locale = .current,
        onQuizStart: @escaping (QuizFeatureCard.Kind) -> Void,
        onSuggestionTap: @escaping (String) -> Void
    ) {
        self.quizPosterURLs = quizPosterURLs
        self.locale = locale
        self.onQuizStart = onQuizStart
        self.onSuggestionTap = onSuggestionTap
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("chat.whatToWatchTonight.tooltip", bundle: .module)
                        .font(.system(size: 22, weight: .semibold))
                    Text("chat.quizATipOr.tooltip", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)
                .padding(.horizontal, 24)

                QuizFeatureCard(posterURLs: quizPosterURLs, onStart: onQuizStart)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                HStack(spacing: 12) {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
                    Text("chat.orAsk.button", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)

                VStack(spacing: 10) {
                    ForEach(suggestionKeys, id: \.self) { key in
                        SuggestionPromptRow(LocalizedStringKey(key)) {
                            // Send the prompt in the in-app language so it
                            // matches the chip's (env-locale) label — not the
                            // process language, which lags until relaunch.
                            onSuggestionTap(AppLocalized.string(key, locale: locale))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
    }
}
