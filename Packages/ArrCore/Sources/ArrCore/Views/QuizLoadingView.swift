import SwiftUI

/// The quiz before its first card: a library cover blurred full-bleed where the card will be,
/// a story where its title will be, Cancel where its buttons will be.
struct QuizLoadingView: View {
    let phase: DiscoverViewModel.LoadPhase
    let startedAt: Date?
    /// Covers of the picks resolved so far; the newest takes over the backdrop.
    let posters: [URL]
    /// Replaces the phase line, for a top-up round that has no phases of its own.
    var label: LocalizedStringKey?
    let onCancel: () -> Void

    @Environment(ConfigStore.self) private var configStore
    /// A stand-in from the user's library until the model's picks start landing.
    @State private var library: [URL] = LibraryPosterSampler.cached ?? []
    @State private var stories: [WaitStory] = []

    private static let slowAfter: TimeInterval = 20

    var body: some View {
        ZStack(alignment: .bottom) {
            WaitPosterLayer(poster: (posters.last ?? library.first).map { WaitPoster(url: $0) })
            WaitStage(stories: stories) {
                VStack(alignment: .leading, spacing: 6) {
                    WaitStatusLine(label: label ?? phaseKey)
                        .animation(.smooth(duration: 0.3), value: phase)
                    slowHint
                }
            }
            .padding(.bottom, QuizLayout.cardBottomInset)
            GlassCircleButton(systemName: "xmark", tint: .secondary, accessibilityKey: "Cancel", action: onCancel)
                .padding(.bottom, QuizLayout.buttonBottomPadding)
        }
        .environment(\.colorScheme, .dark)
        .task {
            stories = WaitFacts.watching().shuffled().map { WaitStory(sentence: $0.text) }
            let owned = await WaitFacts.library(configStore: configStore)
            stories = (stories + owned.map { WaitStory(sentence: $0.text) }).shuffled()
            if library.isEmpty {
                library = await LibraryPosterSampler.sample(configStore: configStore)
            }
        }
    }

    private var phaseKey: LocalizedStringKey {
        switch phase {
        case .askingModel: "discover.loading.askingModel"
        case .resolving: "discover.loading.matching"
        }
    }

    private var slowHint: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let startedAt, context.date.timeIntervalSince(startedAt) > Self.slowAfter {
                Text("discover.loading.slow", bundle: .module)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
