import SwiftUI

/// Resume widget shown in chat after a `discover_in_quiz` tool call —
/// stacked-poster deck visual that telegraphs "you have a Quiz session
/// in progress, tap to come back". Picks count overlays as a chip so
/// the user reads it without leaving the chat.
///
/// Tap on the deck fires `arrBarrOpenDiscoverQuiz` with `append: true`
/// and an empty items list — the receiver (`PopoverContentView`)
/// interprets that as "reopen the overlay without disturbing the
/// current session" and flips `showDiscoverOverlay = true`.
public struct QuizResumeCard: View {
    let mood: String
    let posterURLs: [URL]
    /// Direct singleton ref — chat-message-bubble context doesn't
    /// always propagate `@EnvironmentObject` reliably across the
    /// `ChatTabContent` / `RichToolResultView` boundary; sticking to
    /// the shared instance avoids a "No ObservableObject found" trap.
    private var discoverViewModel = DiscoverViewModel.shared

    public init(mood: String, posterURLs: [URL]) {
        self.mood = mood
        self.posterURLs = posterURLs
    }

    /// Live count of matched items in the current Quiz session.
    private var pickedCount: Int {
        discoverViewModel.sessionMatched.count
    }

    public var body: some View {
        Button(action: resumeQuiz) {
            VStack(alignment: .leading, spacing: 8) {
                deckHeader

                // Stacked poster deck — top three posters offset and
                // rotated slightly so the eye reads "this is a swipe
                // deck", not a single card. Empty posters list falls
                // back to a single placeholder so the card still has
                // a visual anchor.
                deck

                // Bottom row — mood blurb + picks chip.
                HStack(spacing: 6) {
                    if !mood.isEmpty {
                        Text(verbatim: "“\(mood)”")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    pickedChip
                }
            }
            .padding(12)
            .frame(maxWidth: 280, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Color.purple.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .stroke(Color.purple.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var deckHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.purple)
            Text("discover.quiz.button", bundle: .module)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var deck: some View {
        let visible = Array(posterURLs.prefix(4))
        ZStack(alignment: .leading) {
            // Render back-to-front so the topmost poster is the last
            // child in the ZStack (paints over the deeper ones).
            ForEach(Array(visible.enumerated().reversed()), id: \.offset) { idx, url in
                posterCard(url: url, index: idx)
            }
            if visible.isEmpty {
                emptyDeckPlaceholder
            }
        }
        .frame(height: 110)
    }

    @ViewBuilder
    private func posterCard(url: URL, index: Int) -> some View {
        // Each card offsets +18pt horizontally and gets a small
        // counter-rotation — fanned-deck look without overlapping
        // text below.
        let xOffset = CGFloat(index) * 18
        let rotation: Double = [(-3.0), 1.5, -1.0, 2.5][min(index, 3)]
        RemotePoster(
            url: url,
            apiKey: nil,
            size: CGSize(width: 70, height: 105),
            cornerRadius: 4,
            fallbackSymbol: "film"
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .rotationEffect(.degrees(rotation))
        .offset(x: xOffset)
    }

    @ViewBuilder
    private var emptyDeckPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.purple.opacity(0.15))
            .frame(width: 70, height: 105)
            .overlay(
                Image(systemName: "sparkles")
                    .scaledFont(size: 20, weight: .light)
                    .foregroundStyle(.purple)
            )
    }

    @ViewBuilder
    private var pickedChip: some View {
        // "Wybrane: N" pill — only renders when the user has matched
        // at least one item. Otherwise the card reads "Quiz: tap to
        // resume" without a noisy zero count.
        if pickedCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 9, weight: .semibold)
                Text(String(format: NSLocalizedString("discover.pickedCount", bundle: .module, comment: ""), pickedCount))
                    .scaledFont(size: 10, weight: .semibold)
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                    .stroke(Color.green.opacity(0.35), lineWidth: 0.75)
            )
        }
    }

    private func resumeQuiz() {
        // Empty items + append: true → PopoverContentView's existing
        // handler short-circuits seeding (no `extend(items: [])` is a
        // no-op) and just flips `showDiscoverOverlay = true`. Reuses
        // the existing notification rather than adding a parallel one.
        NotificationCenter.default.post(
            name: .arrBarrOpenDiscoverQuiz,
            object: nil,
            userInfo: [
                "mood": mood,
                "items": [DiscoverItem](),
                "append": true,
            ]
        )
    }
}
