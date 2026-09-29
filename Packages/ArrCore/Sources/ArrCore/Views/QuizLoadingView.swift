import SwiftUI

struct QuizLoadingView: View {
    let phase: DiscoverViewModel.LoadPhase
    let startedAt: Date?
    /// Covers of the picks resolved so far; the fan shows the newest three.
    let posters: [URL]
    let onCancel: () -> Void

    @EnvironmentObject private var configStore: ConfigStore
    /// Stand-ins from the user's library until the model's picks start landing.
    @State private var library: [URL] = LibraryPosterSampler.cached ?? []
    @State private var stories: [WaitStory] = []

    private static let slowAfter: TimeInterval = 20

    var body: some View {
        let covers = posters.isEmpty ? library : Array(posters.reversed())
        WaitStage(covers: covers.map { WaitPoster(url: $0) }, slotCount: 3, stories: stories) {
            VStack(spacing: 10) {
                LoadingStateView(label: phaseKey)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.2), value: phase)
                slowHint
                Button(action: onCancel) {
                    Text("Cancel", bundle: .module)
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
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
                    .multilineTextAlignment(.center)
            }
        }
    }
}
