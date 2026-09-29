import SwiftUI

nonisolated struct WaitPoster: Hashable, Sendable {
    let url: URL?
    var apiKey: String? = nil
}

/// A full-bleed cover behind a long wait, blurred and drifting slowly, scrimmed like the quiz card
/// so the text on it reads the same.
struct WaitPosterLayer: View {
    let poster: WaitPoster?

    private struct Shown {
        let poster: WaitPoster
        let image: PlatformImage
    }

    @State private var shown: Shown?
    @State private var lastChange = Date.distantPast

    /// Picks can land several a second; a cover stays at least this long.
    private static var hold: TimeInterval { 2 }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color.black
                // Driven by the clock, not an animation: a repeating animation also caught the first
                // layout pass and grew the cover out of the top-left corner.
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    let drift = (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi / 18)) / 2
                    ZStack {
                        if let shown {
                            Image(platformImage: shown.image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: size.width, height: size.height)
                                .id(shown.poster)
                                // Fades in while settling back from a closer zoom; the old cover leaves
                                // only once the new one covers it, so there's no dim midpoint.
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 1.14)),
                                    removal: .opacity.animation(.linear(duration: 0.1).delay(1.5))))
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(1.18 + 0.08 * drift)
                    .offset(x: -size.width * 0.03 * drift, y: size.height * 0.02 * drift)
                }
                .blur(radius: 28, opaque: true)
                .saturation(1.25)
                Color.black.opacity(0.22)
                scrim(size)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: poster) { await show(poster) }
    }

    /// The quiz card's bottom scrim, plus a light one at the top for the header or back button.
    private func scrim(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: size.height * 0.55)
        }
    }

    private func show(_ poster: WaitPoster?) async {
        guard let poster, let url = poster.url else { return }
        let wait = Self.hold - Date().timeIntervalSince(lastChange)
        if shown != nil, wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        // Loaded before it shows, so it fades in whole rather than popping in over a blank.
        guard let image = await PosterStore.shared.image(for: url, tier: .card, apiKey: poster.apiKey),
              !Task.isCancelled else { return }
        lastChange = Date()
        withAnimation(.easeOut(duration: 1.4)) { shown = Shown(poster: poster, image: image) }
    }
}

/// The text of a long wait: a "Did you know" line and the host's status under it, set where the
/// quiz card puts its title so the wait reads as the card still developing. Sits on `WaitPosterLayer`.
struct WaitStage<Footer: View>: View {
    let stories: [WaitStory]
    var interval: TimeInterval = 7
    @ViewBuilder var footer: () -> Footer

    @State private var index = 0
    /// A person card is open: the story holds still under it.
    @State private var holding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                if let story {
                    WaitStoryText(story: story, holding: $holding)
                        .id(story.id)
                        .transition(.opacity)
                }
            }
            // Room for a long story up front, so the status line doesn't hop as they change.
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .bottomLeading)
            footer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .environment(\.colorScheme, .dark)
        // Late stories (TMDB answers after the first turn) must not swap the line being read.
        .onChange(of: stories.map(\.id)) { old, new in
            guard !old.isEmpty else { return }
            index = new.firstIndex(of: old[index % old.count]) ?? 0
        }
        .task(id: "\(index)-\(holding)-\(stories.count)") {
            guard !holding, stories.count > 1 else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { index += 1 }
        }
    }

    private var story: WaitStory? {
        stories.isEmpty ? nil : stories[index % stories.count]
    }
}

/// The spinner and what is being waited on, in one quiet line.
struct WaitStatusLine: View {
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label, bundle: .module)
                .scaledFont(size: 12.5)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
    }
}

private struct WaitStoryText: View {
    let story: WaitStory
    @Binding var holding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("wait.story.lead", bundle: .module)
                .scaledFont(size: 10.5, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.9)
            Text(markdown(story.sentence))
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(.primary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            if !story.people.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(story.people.prefix(4).enumerated()), id: \.offset) { _, person in
                        PersonFace(person: person, holding: $holding)
                    }
                }
                .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// On macOS a face with a TMDB id opens the same person card as the detail's cast row.
private struct PersonFace: View {
    let person: WaitStory.Person
    @Binding var holding: Bool
    @Environment(ConfigStore.self) private var configStore

    var body: some View {
        #if os(macOS)
        if let id = person.tmdbPersonId {
            face.hoverTooltip(arrowEdge: .top, hovering: $holding) {
                CastTooltip(person: CastMember(id: "wait-\(id)", name: person.name, role: person.role,
                                               imageURL: person.imageURL, tmdbPersonId: id),
                            tmdbKey: configStore.tmdbApiKey)
            }
        } else {
            face
        }
        #else
        face
        #endif
    }

    private var face: some View {
        RemotePoster(url: person.imageURL, apiKey: nil, tier: .icon,
                     size: CGSize(width: 34, height: 34), cornerRadius: 17, fallbackSymbol: "person.fill")
            .accessibilityLabel(Text(verbatim: person.name))
    }
}
