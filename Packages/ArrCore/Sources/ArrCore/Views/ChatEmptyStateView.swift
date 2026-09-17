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
    /// chip sends an English question, a Polish chip a Polish one, etc.
    ///
    /// The pool is deliberately longer than the five slots on screen: every one
    /// of these is a thing the tools can actually answer, and a fixed four made
    /// the chat look like it knew four tricks. Slots rotate through the rest
    /// (see `rotate`), so the surface keeps suggesting something new without
    /// ever growing into a wall of buttons.
    static let suggestionPool: [String] = [
        "chat.empty.suggest.upcoming",
        "chat.empty.suggest.queue",
        "chat.empty.suggest.tasteMrRobot",
        "chat.empty.suggest.personSwinton",
        "chat.empty.suggest.shortTonight",
        "chat.empty.suggest.familyNight",
        "chat.empty.suggest.bingeWeekend",
        "chat.empty.suggest.bestUnwatched",
        "chat.empty.suggest.classic",
        "chat.empty.suggest.surpriseMe",
        "chat.empty.suggest.missingEpisodes",
        "chat.empty.suggest.stuckQueue",
        "chat.empty.suggest.diskSpace",
        "chat.empty.suggest.likeBladeRunner",
        "chat.empty.suggest.thisWeek",
        "chat.empty.suggest.rainyEvening",
    ]

    /// How many are on screen at once.
    private static let visibleCount = 5
    /// One slot changes at a time, and slowly: this sits under a chat composer
    /// the user may be reading, so the movement has to be noticeable without
    /// becoming a carousel demanding attention.
    private static let rotationInterval = Duration.seconds(6)

    @State private var visibleKeys: [String] = Array(suggestionPool.prefix(visibleCount))
    /// Which slot changes next — walking down the list rather than picking at
    /// random, so two neighbouring rows never swap in the same beat.
    @State private var nextSlot = 0
    /// How many rows the fitted layout actually placed (see `suggestions`).
    @State private var shownCount = visibleCount
    /// Rotation is motion for its own sake; anyone who has asked the system to
    /// stop that gets the first five and silence.
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
        .onAppear(perform: seed)
        .task { await rotate() }
    }

    /// As many suggestions as the panel can actually show. The candidates are
    /// measured for real, so a wrapped two-line row in German counts double
    /// exactly as it should — which is why this isn't arithmetic over an
    /// assumed row height.
    @ViewBuilder
    private var suggestions: some View {
        ViewThatFits(in: .vertical) {
            suggestionStack(5)
            suggestionStack(4)
            suggestionStack(3)
            suggestionStack(2)
            suggestionStack(1)
        }
    }

    private func suggestionStack(_ count: Int) -> some View {
        VStack(spacing: 10) {
            ForEach(visibleKeys.prefix(count), id: \.self) { key in
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
        .padding(.bottom, 16)
        // Only the candidate that fits is ever placed, so this is the honest
        // answer to "how many are on screen" — and the rotation needs it, or a
        // beat lands on a row nobody can see.
        .onAppear { shownCount = count }
    }

    /// Start from a different five each time the empty state is built —
    /// reopening the panel shouldn't feel like reopening the same poster.
    private func seed() {
        guard visibleKeys == Array(Self.suggestionPool.prefix(Self.visibleCount)) else { return }
        visibleKeys = Array(Self.suggestionPool.shuffled().prefix(Self.visibleCount))
    }

    /// Swaps one slot every `rotationInterval` for a suggestion that isn't on
    /// screen. Lives in a `task`, so it stops the moment the empty state does
    /// (a first message, a tab switch, the panel closing).
    private func rotate() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.rotationInterval)
            guard !Task.isCancelled else { return }
            let onScreen = Set(visibleKeys)
            guard let incoming = Self.suggestionPool.filter({ !onScreen.contains($0) }).randomElement() else { return }
            let slot = nextSlot % max(1, shownCount)
            withAnimation(.smooth(duration: 0.45)) {
                visibleKeys[slot] = incoming
            }
            nextSlot = (slot + 1) % max(1, shownCount)
        }
    }
}
