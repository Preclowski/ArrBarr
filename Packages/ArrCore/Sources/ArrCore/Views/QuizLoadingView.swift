import SwiftUI

/// What the quiz overlay shows between "start" and the first card: which
/// stage the deck is in, how far along, and a way out.
struct QuizLoadingView: View {
    let phase: DiscoverViewModel.LoadPhase
    let startedAt: Date?
    let onCancel: () -> Void

    @State private var pulse = false
    @State private var facts: [WaitFact] = []

    private static let slowAfter: TimeInterval = 20

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            cardFan
            VStack(spacing: 8) {
                phaseLabel
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.2), value: phase)
                progressBar
                WaitFactTicker(facts: facts, foreground: .white.opacity(0.6))
                slowHint
            }
            .padding(.horizontal, 32)
            Spacer()
            Button(action: onCancel) {
                Text("Cancel", bundle: .module)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            pulse = true
            facts = WaitFacts.watching()
        }
    }

    private var cardFan: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.06 + Double(index) * 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    )
                    .frame(width: 96, height: 144)
                    .rotationEffect(.degrees(Double(index - 1) * (pulse ? 9 : 5)))
                    .offset(x: CGFloat(index - 1) * (pulse ? 22 : 14))
            }
        }
        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch phase {
        case .askingModel:
            Text("discover.loading.askingModel", bundle: .module)
        case .resolving(let done, let total, _):
            Text("discover.loading.resolving \(done) \(total)", bundle: .module)
        }
    }

    /// Determinate only once the pick count stops growing; a bar whose total
    /// keeps moving reads as going backwards.
    @ViewBuilder
    private var progressBar: some View {
        if case .resolving(let done, let total, true) = phase, total > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(done) / CGFloat(total))
                        .animation(.smooth(duration: 0.25), value: done)
                }
            }
            .frame(width: 160, height: 4)
        }
    }

    private var slowHint: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let startedAt, context.date.timeIntervalSince(startedAt) > Self.slowAfter {
                Text("discover.loading.slow", bundle: .module)
                    .scaledFont(size: 11)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
    }
}
