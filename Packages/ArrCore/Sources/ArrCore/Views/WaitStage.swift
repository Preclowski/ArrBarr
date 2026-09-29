import SwiftUI

nonisolated struct WaitPoster: Hashable, Sendable {
    let url: URL?
    var apiKey: String? = nil
}

/// The shared long-wait screen (quiz deck, manual release search): the cover (a fan when there are
/// several), one "Did you know" line, the host's status at the foot. No backdrop: the window's glass shows.
struct WaitStage<Footer: View>: View {
    /// Newest first; the first is the centre card, up to two more fan out behind it.
    let covers: [WaitPoster]
    /// Stand-ins for covers still on their way: dimmed and desaturated, never see-through.
    var pending = false
    let stories: [WaitStory]
    var interval: TimeInterval = 7
    @ViewBuilder var footer: () -> Footer

    @State private var index = 0
    /// What the fan shows; walks toward `covers` one card at a time.
    @State private var deck: [WaitPoster] = []
    @State private var lastStep = Date.distantPast
    /// A person card is open: the story holds still under it.
    @State private var holding = false
    @State private var breathe = false

    private static var cardSize: CGSize { CGSize(width: 128, height: 192) }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            fan
            ZStack(alignment: .top) {
                if let story {
                    WaitStoryText(story: story, holding: $holding)
                        .id(story.id)
                        .transition(.opacity)
                }
            }
            // Room for a long story up front, so the fan doesn't hop as they change.
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .top)
            Spacer(minLength: 12)
            footer()
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { breathe = true }
        // Late stories (TMDB answers after the first turn) must not swap the line being read.
        .onChange(of: stories.map(\.id)) { old, new in
            guard !old.isEmpty else { return }
            index = new.firstIndex(of: old[index % old.count]) ?? 0
        }
        .task(id: target) { await follow(target) }
        .task(id: "\(index)-\(holding)-\(stories.count)") {
            guard !holding, stories.count > 1 else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.4)) { index += 1 }
        }
    }

    private var story: WaitStory? {
        stories.isEmpty ? nil : stories[index % stories.count]
    }

    // MARK: - Fan

    /// Picks can land several a second; one step per beat reads as a deck being dealt, not a strobe.
    private static var beat: TimeInterval { 0.9 }

    private var target: [WaitPoster] {
        var seen = Set<WaitPoster>()
        return Array(covers.filter { seen.insert($0).inserted }.prefix(3))
    }

    /// A new cover is dealt onto the centre and pushes the others out one slot; anything else
    /// (a cover dropped, the order changed) settles in a single animated step.
    private func follow(_ target: [WaitPoster]) async {
        while !Task.isCancelled, deck != target {
            let wait = Self.beat - Date().timeIntervalSince(lastStep)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            var next = target
            if let incoming = target.first(where: { !deck.contains($0) }) {
                // In before it shows, so the card never lands blank and pops its image in later.
                if let url = incoming.url {
                    _ = await PosterStore.shared.image(for: url, tier: .card, apiKey: incoming.apiKey)
                    guard !Task.isCancelled else { return }
                }
                next = Array(([incoming] + deck).prefix(3))
            }
            lastStep = Date()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) { deck = next }
        }
    }

    private var fan: some View {
        let spread: CGFloat = breathe ? 1 : 0.8
        return ZStack {
            ForEach(Array(deck.enumerated()), id: \.element) { slot, poster in
                let direction: CGFloat = slot == 0 ? 0 : (slot == 1 ? -1 : 1)
                card(poster)
                    .brightness(slot == 0 ? 0 : -0.28)
                    .scaleEffect(slot == 0 ? 1 : 0.9)
                    .rotationEffect(.degrees(Double(direction) * 9 * spread))
                    .offset(x: direction * 58 * spread, y: slot == 0 ? 0 : 8)
                    .zIndex(Double(3 - slot))
                    .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity),
                                            removal: .scale(scale: 0.9).combined(with: .opacity)))
            }
        }
        .saturation(pending ? 0.35 : 1)
        .brightness(pending ? -0.15 : 0)
        .frame(height: Self.cardSize.height + 16)
        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathe)
        .animation(.smooth(duration: 0.6), value: pending)
        .accessibilityHidden(true)
    }

    private func card(_ poster: WaitPoster) -> some View {
        RemotePoster(url: poster.url, apiKey: poster.apiKey, tier: .card,
                     size: Self.cardSize, cornerRadius: Tokens.Radius.card, fallbackSymbol: "film")
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            // RemotePoster's placeholder is translucent; a card in a fan must hide the one behind it.
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
    }
}

private struct WaitStoryText: View {
    let story: WaitStory
    @Binding var holding: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text("wait.story.lead", bundle: .module)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.9)
            Text(markdown(story.sentence))
                .scaledFont(size: 15)
                .foregroundStyle(.primary)
                .lineSpacing(2)
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
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// On macOS a face with a TMDB id opens the same person card as the detail's cast row.
private struct PersonFace: View {
    let person: WaitStory.Person
    @Binding var holding: Bool
    @EnvironmentObject private var configStore: ConfigStore

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
