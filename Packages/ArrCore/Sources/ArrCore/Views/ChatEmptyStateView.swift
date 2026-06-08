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

    private struct Suggestion {
        let key: LocalizedStringKey
        let prompt: String
    }

    private let suggestions: [Suggestion] = [
        .init(key: "chat.empty.suggest.upcoming",  prompt: "Co dziś wychodzi?"),
        .init(key: "chat.empty.suggest.queue",     prompt: "Co się teraz ściąga?"),
        .init(key: "chat.empty.suggest.tasteMrRobot", prompt: "Polecisz coś jak Mr. Robot?"),
        .init(key: "chat.empty.suggest.personSwinton", prompt: "Filmy z Tildą Swinton"),
    ]

    public init(
        quizPosterURLs: [URL] = [],
        onQuizStart: @escaping (QuizFeatureCard.Kind) -> Void,
        onSuggestionTap: @escaping (String) -> Void
    ) {
        self.quizPosterURLs = quizPosterURLs
        self.onQuizStart = onQuizStart
        self.onSuggestionTap = onSuggestionTap
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("chat.empty.greeting", bundle: .module)
                        .font(.system(size: 22, weight: .semibold))
                    Text("chat.empty.subhead", bundle: .module)
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
                    Text("chat.empty.divider", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)

                VStack(spacing: 10) {
                    ForEach(suggestions, id: \.prompt) { s in
                        SuggestionPromptRow(s.key) { onSuggestionTap(s.prompt) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
    }
}
