import SwiftUI

/// Claude-style animated "thinking" indicator. Two effects combined:
/// 1. A horizontal color wave (linear gradient) sweeps across the letters
///    continuously — like wet ink catching light.
/// 2. The verb phrase rotates every ~2.5s through a list of evocative
///    synonyms so the user feels something is happening, not just spinning.
/// Drop-in replacement for "ProgressView + Text('Thinking…')" UI.
public struct ShimmerThinkingLabel: View {
    /// Phrases to rotate through. Default list reads like Claude's UI.
    let phrases: [LocalizedStringKey]

    public init(phrases: [LocalizedStringKey] = ShimmerThinkingLabel.defaultPhrases) {
        self.phrases = phrases
    }

    /// Stock phrase list, localizable.
    public static let defaultPhrases: [LocalizedStringKey] = [
        "Thinking…",
        "Weighing options…",
        "Considering…",
        "Evaluating…",
        "Finding ideas…",
    ]

    @State private var phraseIndex: Int = 0

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // 0..1 phase, full loop every 2.4 seconds.
            let phase = (t.truncatingRemainder(dividingBy: 2.4)) / 2.4
            Text(phrases[phraseIndex], bundle: .module)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .secondary, location: 0),
                            .init(color: .secondary, location: max(0, phase - 0.25)),
                            .init(color: .primary,   location: phase),
                            .init(color: .secondary, location: min(1, phase + 0.25)),
                            .init(color: .secondary, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .transition(.opacity)
                .id(phraseIndex)
        }
        .task {
            // Phrase rotation — independent of the gradient timeline.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation(.easeInOut(duration: 0.4)) {
                    phraseIndex = (phraseIndex + 1) % phrases.count
                }
            }
        }
    }
}
