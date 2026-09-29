import SwiftUI

nonisolated struct WaitPoster: Hashable, Sendable {
    let url: URL?
    var apiKey: String? = nil
}

/// The shared long-wait screen: one cover (release search) or a fan of three (quiz) over soft blots
/// of their colour, one "Did you know" line, the host's status at the foot. No backdrop: the window's glass shows.
struct WaitStage<Footer: View>: View {
    /// Newest first. Real covers fill the slots as they come; stand-ins (`pending`) take turns.
    let covers: [WaitPoster]
    /// 1 or 3: the centre card, then left and right.
    var slotCount = 1
    /// Stand-ins for covers still on their way: dimmed and desaturated, never see-through.
    var pending = false
    let stories: [WaitStory]
    var interval: TimeInterval = 7
    @ViewBuilder var footer: () -> Footer

    @State private var index = 0
    /// Cards never move; a new cover crossfades into a slot in place.
    @State private var slots: [WaitPoster?] = []
    @State private var lastChange = Date.distantPast
    @State private var tint: Color?
    /// A person card is open: the story holds still under it.
    @State private var holding = false

    /// Picks land several a second; a slot changes at most this often so it reads as a change, not a strobe.
    private static var hold: TimeInterval { 1.2 }
    private static var standInHold: TimeInterval { 1.6 }
    /// Empty slots fill quickly, so the fan is up almost at once.
    private static var fillHold: TimeInterval { 0.25 }

    var body: some View {
        GeometryReader { proxy in
            let height = min(slotCount == 1 ? 300 : 255, proxy.size.height * (slotCount == 1 ? 0.5 : 0.44))
            VStack(spacing: 16) {
                Spacer(minLength: 20)
                fan(CGSize(width: height / 1.5, height: height))
                ZStack(alignment: .top) {
                    if let story {
                        WaitStoryText(story: story, holding: $holding)
                            .id(story.id)
                            .transition(.opacity)
                    }
                }
                // Room for a long story up front, so the cover doesn't hop as they change.
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .top)
                Spacer(minLength: 8)
                footer()
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Late stories (TMDB answers after the first turn) must not swap the line being read.
        .onChange(of: stories.map(\.id)) { old, new in
            guard !old.isEmpty else { return }
            index = new.firstIndex(of: old[index % old.count]) ?? 0
        }
        .task(id: covers) { await follow() }
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

    // MARK: - Cards

    private func follow() async {
        if slots.count != slotCount { slots = Array(repeating: nil, count: slotCount) }
        var turn = 0
        while !Task.isCancelled, let (slot, next) = nextChange(turn: turn) {
            turn += 1
            let pace = slots.contains(where: { $0 == nil }) ? Self.fillHold : (pending ? Self.standInHold : Self.hold)
            let wait = pace - Date().timeIntervalSince(lastChange)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            // In before it shows, so a card never fades in blank and pops its image later.
            if let url = next.url {
                _ = await PosterStore.shared.image(for: url, tier: .card, apiKey: next.apiKey)
            }
            guard !Task.isCancelled else { return }
            lastChange = Date()
            withAnimation(.easeInOut(duration: 0.9)) { slots[slot] = next }
            tint = await PosterTint.color(for: next.url) ?? tint
        }
    }

    /// Real covers: the oldest one not yet up takes the first slot holding nothing current.
    /// Stand-ins: the next one not on screen takes the next slot in turn, for as long as the wait lasts.
    private func nextChange(turn: Int) -> (Int, WaitPoster)? {
        let unique = covers.reduce(into: [WaitPoster]()) { if !$0.contains($1) { $0.append($1) } }
        if pending {
            guard let next = unique.first(where: { !slots.contains($0) }) ?? unique.first,
                  unique.count > slotCount || slots.contains(where: { $0 == nil }) else { return nil }
            let slot = slots.firstIndex(where: { $0 == nil }) ?? turn % slotCount
            return (slot, next)
        }
        let current = Array(unique.prefix(slotCount))
        guard let incoming = current.last(where: { !slots.contains($0) }),
              let slot = slots.firstIndex(where: { $0 == nil || !current.contains($0!) }) else { return nil }
        return (slot, incoming)
    }

    private func fan(_ size: CGSize) -> some View {
        ZStack {
            WaitTintBlots(tint: tint ?? .accentColor, size: size)
                .animation(.easeInOut(duration: 1.2), value: tint)
            ForEach(Array(slots.enumerated()).reversed(), id: \.offset) { slot, poster in
                let direction: CGFloat = slot == 0 ? 0 : (slot == 1 ? -1 : 1)
                card(poster, size: size)
                    .brightness(slot == 0 ? 0 : -0.22)
                    .scaleEffect(slot == 0 ? 1 : 0.82)
                    .rotationEffect(.degrees(Double(direction) * 8))
                    .offset(x: direction * size.width * 0.46, y: slot == 0 ? 0 : 10)
            }
        }
        .frame(width: size.width, height: size.height)
        .saturation(pending ? 0.35 : 1)
        .brightness(pending ? -0.15 : 0)
        .animation(.smooth(duration: 0.6), value: pending)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func card(_ poster: WaitPoster?, size: CGSize) -> some View {
        if let poster {
            ZStack {
                // The base stays put under the crossfade, so the glass never shows through mid-change.
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Color(white: 0.16))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                RemotePoster(url: poster.url, apiKey: poster.apiKey, tier: .card,
                             size: size, cornerRadius: Tokens.Radius.card, fallbackSymbol: "film")
                    .frame(width: size.width, height: size.height)
                    .id(poster)
                    .transition(.opacity)
            }
            .frame(width: size.width, height: size.height)
            .transition(.opacity)
        }
    }
}

/// Soft blots of the cover's colour drifting under it, like light through tinted glass.
private struct WaitTintBlots: View {
    let tint: Color
    let size: CGSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = Double(i) * 2.1
                    Circle()
                        .fill(tint)
                        .hueRotation(.degrees(Double(i - 1) * 30))
                        .frame(width: size.width * 0.95, height: size.width * 0.95)
                        .offset(x: cos(t * 0.33 + phase) * size.width * 0.32,
                                y: sin(t * 0.25 + phase) * size.height * 0.26)
                }
            }
            .blur(radius: 48)
            .opacity(0.75)
        }
        .allowsHitTesting(false)
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
