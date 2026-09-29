import SwiftUI

nonisolated struct WaitPoster: Hashable, Sendable {
    let url: URL?
    var apiKey: String? = nil
}

/// The shared long-wait screen: one cover (release search) or a fan of three (quiz) over soft blots
/// of their colour, one "Did you know" line, the host's status at the foot. No backdrop: the window's glass shows.
struct WaitStage<Footer: View>: View {
    /// Newest first; the first `slotCount` are shown.
    let covers: [WaitPoster]
    /// 1 or 3: the centre card, then left and right.
    var slotCount = 1
    let stories: [WaitStory]
    var interval: TimeInterval = 7
    @ViewBuilder var footer: () -> Footer

    @State private var index = 0
    @State private var slots: [WaitSlot] = []
    @State private var lastChange = Date.distantPast
    @State private var tint: Color?
    @State private var breathe = false
    /// A person card is open: the story holds still under it.
    @State private var holding = false

    /// Picks land several a second; a slot changes at most this often so it reads as a change, not a strobe.
    private static var hold: TimeInterval { 1.4 }
    /// Empty slots fill quickly, so the fan is up almost at once.
    private static var fillHold: TimeInterval { 0.2 }

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
        .onAppear { breathe = true }
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
        if slots.count != slotCount { slots = Array(repeating: WaitSlot(), count: slotCount) }
        while !Task.isCancelled, let (slot, next) = nextChange() {
            let pace = slots.contains(where: { $0.poster == nil }) ? Self.fillHold : Self.hold
            let wait = pace - Date().timeIntervalSince(lastChange)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            // Loaded before it shows, and drawn from memory: no placeholder frame mid-fade.
            var image: PlatformImage?
            if let url = next.url {
                image = await PosterStore.shared.image(for: url, tier: .card, apiKey: next.apiKey)
            }
            guard !Task.isCancelled, slots.indices.contains(slot) else { return }
            lastChange = Date()
            if let color = image.flatMap(PosterTint.averageColor(of:)) { tint = Self.vivid(color) }
            slots[slot].poster = next
            if !slots[slot].shown {
                slots[slot].image = image
                withAnimation(.easeOut(duration: 0.5)) { slots[slot].shown = true }
            } else {
                // The new cover fades in over the old one, which stays fully opaque until it is covered.
                withAnimation(.easeInOut(duration: 0.8)) {
                    slots[slot].incoming = WaitSlot.Incoming(image: image)
                } completion: {
                    var settle = Transaction()
                    settle.disablesAnimations = true
                    withTransaction(settle) {
                        slots[slot].image = image
                        slots[slot].incoming = nil
                    }
                }
            }
        }
    }

    /// The oldest cover not yet up takes the first slot holding nothing current.
    private func nextChange() -> (Int, WaitPoster)? {
        let unique = covers.reduce(into: [WaitPoster]()) { if !$0.contains($1) { $0.append($1) } }
        let current = Array(unique.prefix(slotCount))
        guard let incoming = current.last(where: { cover in !slots.contains { $0.poster == cover } }),
              let slot = slots.firstIndex(where: { $0.poster.map { !current.contains($0) } ?? true }) else { return nil }
        return (slot, incoming)
    }

    private func fan(_ size: CGSize) -> some View {
        let spread: CGFloat = breathe ? 1 : 0.94
        return ZStack {
            WaitTintBlots(tint: tint ?? .accentColor, size: size)
                .animation(.easeInOut(duration: 1.5), value: tint)
            ForEach(Array(slots.enumerated()).reversed(), id: \.offset) { slot, state in
                let direction: CGFloat = slot == 0 ? 0 : (slot == 1 ? -1 : 1)
                if state.shown {
                    WaitCard(slot: state, size: size)
                        .scaleEffect(slot == 0 ? 1 : 0.82)
                        .rotationEffect(.degrees(Double(direction) * 8 * spread))
                        .offset(x: direction * size.width * 0.46 * spread, y: slot == 0 ? 0 : 10)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: breathe)
        .accessibilityHidden(true)
    }

    /// Poster averages come out muddy; the blots need the hue at full voice. Near-greys stay grey.
    private static func vivid(_ color: Color) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return color }
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        return Color(hue: h, saturation: s < 0.08 ? s : max(s, 0.6), brightness: max(b, 0.85))
    }
}

private struct WaitSlot: Equatable {
    struct Incoming: Equatable { let image: PlatformImage? }
    var poster: WaitPoster?
    var image: PlatformImage?
    var incoming: Incoming?
    var shown = false
}

private struct WaitCard: View {
    let slot: WaitSlot
    let size: CGSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        ZStack {
            face(slot.image)
            if let incoming = slot.incoming {
                face(incoming.image).transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 14, y: 7)
    }

    @ViewBuilder
    private func face(_ image: PlatformImage?) -> some View {
        if let image {
            Image(platformImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
        } else {
            ZStack {
                Color(white: 0.2)
                Image(systemName: "film")
                    .font(.system(size: size.width * 0.3, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

/// Soft blots of the covers' colour drifting around and past the cards, like light through tinted glass.
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
                        .hueRotation(.degrees(Double(i - 1) * 28))
                        .frame(width: size.width * 1.25, height: size.width * 1.25)
                        .offset(x: cos(t * 0.3 + phase) * size.width * 0.75,
                                y: sin(t * 0.23 + phase) * size.height * 0.32)
                }
            }
            .blur(radius: 56)
            .opacity(0.7)
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
