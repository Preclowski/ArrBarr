import SwiftUI

/// Chat widget after a `discover_in_quiz` call. Tapping posts `OpenDiscoverQuiz` with no items
/// and `append: true`, which reopens the overlay without touching the session.
struct QuizResumeCard: View {
    let mood: String
    let posterURLs: [URL]
    /// The shared instance: `@EnvironmentObject` doesn't reliably reach chat bubbles.
    private var discoverViewModel = DiscoverViewModel.shared

    init(mood: String, posterURLs: [URL]) {
        self.mood = mood
        self.posterURLs = posterURLs
    }

    private var pickedCount: Int {
        discoverViewModel.sessionMatched.count
    }

    var body: some View {
        Button(action: resumeQuiz) {
            VStack(alignment: .leading, spacing: 8) {
                deckHeader

                deck

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
        if pickedCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 9, weight: .semibold)
                Text(String.localizedStringWithFormat(NSLocalizedString("discover.pickedCount", bundle: .module, comment: ""), pickedCount))
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
        AppMessages.post(AppMessages.OpenDiscoverQuiz(items: [], append: true))
    }
}
