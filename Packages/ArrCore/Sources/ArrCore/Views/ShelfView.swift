import SwiftUI
import QuartzCore

enum ShelfMode: String, CaseIterable, Identifiable {
    case coverFlow, morph, warp, tunnel, globe

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .coverFlow: "shelf.mode.coverFlow"
        case .warp: "shelf.mode.warp"
        case .morph: "shelf.mode.morph"
        case .tunnel: "shelf.mode.tunnel"
        case .globe: "shelf.mode.globe"
        }
    }

    var symbol: String {
        switch self {
        case .coverFlow: "square.stack.3d.forward.dottedline"
        case .warp: "rectangle.expand.vertical"
        case .morph: "drop.halffull"
        case .tunnel: "target"
        case .globe: "globe.europe.africa"
        }
    }
}

/// Scroll state read by the scene on each display tick. Only `center` and `active` are observed, so a scroll
/// event never re-evaluates the Shelf's body; the TimelineView alone redraws, and only while `active`.
@Observable
final class ShelfMotion {
    private(set) var center = 0
    private(set) var active = false
    @ObservationIgnored private(set) var position: Double = 0
    @ObservationIgnored private var velocity: Double = 0
    @ObservationIgnored private var stamp: CFTimeInterval = CACurrentMediaTime()
    @ObservationIgnored private var settle: Task<Void, Never>?

    func track(offset: CGFloat, pitch: CGFloat) {
        let now = CACurrentMediaTime()
        let next = Double(offset / pitch)
        let dt = now - stamp
        if abs(next - position) > 40 {
            // A programmatic jump (recentring on the span), not a flick: it must not smear the effects.
            velocity = 0
        } else if dt > 0.001 {
            velocity = velocity * 0.6 + (next - position) / dt * 0.4
        }
        position = next
        stamp = now
        let rounded = Int(next.rounded())
        if rounded != center { center = rounded }
        if !active { active = true }
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.active = false
        }
    }

    /// Posters per second.
    func velocity(at now: CFTimeInterval) -> Double {
        // The frame drawn as the tick pauses must be the clean one; speed effects would freeze mid-glitch.
        active ? velocity * exp(-(now - stamp) * 7) : 0
    }
}

/// Card-tier posters near the centre (they fill most of the popover), icon tier for the rest of the window.
@Observable
final class ShelfPosters {
    private(set) var small: [String: PlatformImage] = [:]
    private(set) var large: [String: PlatformImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    func image(for id: String) -> PlatformImage? { large[id] ?? small[id] }

    /// Nearest first, both ways round: the Shelf wraps, so the last posters sit just before the first.
    func prefetch(_ entries: [LibraryEntry], around center: Int, apiKey: String) {
        guard !entries.isEmpty else { return }
        let offsets = [0] + (1...20).flatMap { [$0, -$0] }
        let entry = { (k: Int) in entries[(center + k).shelfWrapped(into: entries.count)] }
        for k in offsets {
            fetch(entry(k), tier: abs(k) <= 4 ? .card : .icon, apiKey: apiKey)
        }
        let keep = Set(offsets.map { entry($0).id })
        if small.count > 140 { small = small.filter { keep.contains($0.key) } }
        if large.count > 20 {
            let near = Set(offsets.filter { abs($0) <= 6 }.map { entry($0).id })
            large = large.filter { near.contains($0.key) }
        }
    }

    private func fetch(_ entry: LibraryEntry, tier: PosterTier, apiKey: String) {
        let key = "\(tier.rawValue)|\(entry.id)"
        let have = tier == .card ? large[entry.id] : small[entry.id]
        guard have == nil, !inFlight.contains(key), let url = entry.posterURL else { return }
        inFlight.insert(key)
        let auth = entry.posterRequiresAuth ? apiKey : nil
        Task {
            let image = await PosterStore.shared.image(for: url, tier: tier, apiKey: auth)
            inFlight.remove(key)
            guard let image else { return }
            if tier == .card { large[entry.id] = image } else { small[entry.id] = image }
        }
    }
}

struct ShelfView: View {
    @Environment(ConfigStore.self) var configStore
    /// A pushed detail covers the Shelf: stop the display tick.
    let isObscured: Bool
    let onClose: (() -> Void)?

    @State private var library = LibraryViewModel()
    @State private var posters = ShelfPosters()
    @State private var motion = ShelfMotion()
    @State private var scroll = ScrollPosition(edge: .leading)
    @State private var mode: ShelfMode
    /// Debug harness only: parks the scroll here once the library lands.
    private let initialPosition: Double?
    @State private var start = CACurrentMediaTime()
    @State private var hoveredMode: ShelfMode?
    @State private var filter = ShelfFilter(source: .radarr)
    /// Sources whose first load in this Shelf has finished; until then every empty state is a loading screen.
    @State private var settled: Set<QueueItem.Source> = []
    /// Set once the first centre poster has landed (or after a timeout), so the opening frame is never placeholders.
    @State private var revealed = false

    init(isObscured: Bool, initialMode: ShelfMode = .warp, initialPosition: Double? = nil, onClose: (() -> Void)? = nil) {
        self.isObscured = isObscured
        self.initialPosition = initialPosition
        self.onClose = onClose
        _mode = State(initialValue: initialMode)
    }

    /// Scroll points per poster. Smaller than the visual spacing so one flick crosses dozens of posters.
    static let pitch: CGFloat = 70

    /// Posters in the scroll range. The library repeats across it, so there is no first or last poster:
    /// the scroll starts mid-span and 20 000 posters is further than anyone flicks.
    static let span = 20_000

    /// The start of the scroll: mid-span, on a copy of the first poster.
    private static func home(_ count: Int) -> Int { count > 0 ? span / 2 / count * count : 0 }

    private var source: QueueItem.Source { filter.source }

    private var sources: [QueueItem.Source] {
        let configured = [QueueItem.Source.radarr, .sonarr].filter { configStore.config(for: $0.serviceKind).isConfigured }
        return configured.isEmpty ? [.radarr] : configured
    }

    private var apiKey: String { configStore.config(for: source.serviceKind).apiKey }

    private var entries: [LibraryEntry] {
        let f = filter
        let sorted = library.sorted(f.source, cacheKey: f.sortKey, using: f.areInIncreasingOrder)
        guard f.isNarrowed else { return sorted }
        return library.visible(f.source, cacheKey: f.key, from: sorted, where: f.matches)
    }

    private var centerIndex: Int { motion.center.shelfWrapped(into: entries.count) }

    private func sceneReady(_ entries: [LibraryEntry]) -> Bool {
        revealed || (!entries.isEmpty && posters.image(for: entries[centerIndex].id) != nil)
    }

    var body: some View {
        let entries = entries
        GeometryReader { geo in
            ZStack {
                if sceneReady(entries) {
                TimelineView(.animation(paused: isObscured || !motion.active)) { timeline in
                    ShelfScene(
                        mode: mode,
                        entries: entries,
                        posters: posters,
                        position: motion.position,
                        velocity: motion.velocity(at: CACurrentMediaTime()),
                        time: CACurrentMediaTime() - start,
                        size: geo.size
                    )
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                }
                scrollDriver(entries, size: geo.size)
                chrome(entries)
                if entries.isEmpty {
                    emptyState
                } else if !sceneReady(entries) {
                    LoadingStateView()
                }
            }
        }
        // Under the tab bar too, so the stage fills the whole popover instead of stopping at the glass.
        .background {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    // Pinned: the aspect-fill poster is taller than the stage and would grow it.
                    backdrop(entries)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            .ignoresSafeArea()
        }
        .animation(.easeOut(duration: 0.3), value: revealed)
        .onChange(of: sceneReady(entries)) { _, ready in
            if ready { revealed = true }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            revealed = true
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            if let first = sources.first, !sources.contains(filter.source) { filter.source = first }
        }
        .task(id: filter.source) {
            let loading = filter.source
            await library.loadIfNeeded(source: loading, config: configStore.config(for: loading.serviceKind))
            settled.insert(loading)
        }
        .onChange(of: filter) { _, _ in
            recenter(entries.count)
            posters.prefetch(entries, around: 0, apiKey: apiKey)
        }
        .onChange(of: centerIndex, initial: true) { _, center in
            posters.prefetch(entries, around: center, apiKey: apiKey)
        }
        .onChange(of: entries.count) { old, new in
            // Only the first load recentres; a background refresh that adds a title must not throw you back.
            if old == 0 { recenter(new) }
            posters.prefetch(entries, around: centerIndex, apiKey: apiKey)
        }
        .task(id: entries.count) {
            guard let initialPosition, !entries.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            scroll.scrollTo(x: CGFloat(Double(Self.home(entries.count)) + initialPosition) * Self.pitch)
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private func backdrop(_ entries: [LibraryEntry]) -> some View {
        if entries.indices.contains(centerIndex), let image = posters.image(for: entries[centerIndex].id) {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 60)
                .saturation(1.4)
                .opacity(0.4)
                .id(entries[centerIndex].id)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.5), value: entries[centerIndex].id)
                .allowsHitTesting(false)
                .clipped()
        }
    }

    private func scrollDriver(_ entries: [LibraryEntry], size: CGSize) -> some View {
        ScrollView(.horizontal) {
            Color.clear
                .frame(width: entries.isEmpty ? size.width : CGFloat(Self.span - 1) * Self.pitch + size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    tap(atContentX: location.x, size: size, entries: entries)
                }
        }
        .scrollIndicators(.hidden)
        .scrollPosition($scroll)
        .scrollTargetBehavior(ShelfSnap(pitch: initialPosition == nil ? Self.pitch : 0.001))
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
            motion.track(offset: x, pitch: Self.pitch)
        }
    }

    private func chrome(_ entries: [LibraryEntry]) -> some View {
        VStack(spacing: 0) {
            if let onClose {
                HStack {
                    FloatingBackButton(action: onClose)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            Spacer()
            if entries.indices.contains(centerIndex), sceneReady(entries) {
                ShelfInfo(entry: entries[centerIndex])
                    .padding(.horizontal, 20)
                    .id(entries[centerIndex].id)
                    .transition(.opacity)
            }
            modePicker
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    ShelfFilterMenu(filter: $filter, sources: sources, library: library.entries[source] ?? [],
                                    watchStateKnown: configStore.mediaServer.isConfigured)
                        .padding(.trailing, 12)
                }
                .padding(.top, 12)
                .padding(.bottom, 14)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .frame(height: 200)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: centerIndex)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(ShelfMode.allCases) { m in
                Button { mode = m } label: {
                    Image(systemName: m.symbol)
                        .scaledFont(size: 13, weight: .semibold)
                        .frame(width: 36, height: 30)
                        .background(Capsule().fill(Color.white.opacity(mode == m ? 0.22 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(m.title, bundle: .module))
                .onHover { inside in
                    if inside { hoveredMode = m } else if hoveredMode == m { hoveredMode = nil }
                }
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        // `.help` never shows in the menu-bar panel, so the name floats above the picker instead.
        .overlay(alignment: .top) {
            if let hoveredMode {
                Text(hoveredMode.title, bundle: .module)
                    .scaledFont(size: 11, weight: .semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .fixedSize()
                    .offset(y: -34)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredMode)
    }

    private var emptyState: some View {
        Group {
            if !settled.contains(source) || library.loading.contains(source) || library.entries[source] == nil {
                if library.loadFailed.contains(source), settled.contains(source) {
                    Text("library.error.title", bundle: .module).foregroundStyle(.secondary)
                } else {
                    LoadingStateView()
                }
            } else if filter.isNarrowed {
                Text("Every result is filtered out.", bundle: .module).foregroundStyle(.secondary)
            } else {
                Text("shelf.empty", bundle: .module).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func step(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        let target = min(max(motion.center + delta, 0), Self.span - 1)
        withAnimation(.smooth(duration: 0.4)) { scroll.scrollTo(x: CGFloat(target) * Self.pitch) }
    }

    /// The content width changes in the same update, so the jump waits a beat for layout.
    private func recenter(_ count: Int) {
        guard count > 0 else { return }
        let x = CGFloat(Self.home(count)) * Self.pitch
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            scroll.scrollTo(x: x)
        }
    }

    /// The centre poster opens its detail; a tap either side steps toward it.
    private func tap(atContentX x: CGFloat, size: CGSize, entries: [LibraryEntry]) {
        let screenX = x - CGFloat(motion.position) * Self.pitch
        let half = ShelfScene.heroWidth(for: size) / 2
        if screenX < size.width / 2 - half { step(-1, count: entries.count); return }
        if screenX > size.width / 2 + half { step(1, count: entries.count); return }
        guard entries.indices.contains(centerIndex) else { return }
        let entry = entries[centerIndex]
        DetailRequest.post(DetailRequest.syntheticItem(
            source: entry.source, entityId: entry.arrId, title: entry.title,
            posterURL: entry.posterURL, posterRequiresAuth: entry.posterRequiresAuth))
    }
}

#if DEBUG
/// Opens one mode parked at a fixed position, for checking a frame by screenshot (`-ShelfDebug mode:position`).
public struct ShelfDebugView: View {
    private let mode: ShelfMode
    private let position: Double

    public init(spec: String) {
        let parts = spec.split(separator: ":")
        mode = ShelfMode(rawValue: String(parts.first ?? "")) ?? .coverFlow
        position = parts.count > 1 ? Double(parts[1]) ?? 3.5 : 3.5
    }

    public var body: some View {
        ShelfView(isObscured: false, initialMode: mode, initialPosition: position, onClose: {})
            .frame(width: 400, height: 600)
    }
}
#endif

/// The Quiz card's metadata block: title (year), rating chips, director.
private struct ShelfInfo: View {
    @Environment(ConfigStore.self) var configStore
    let entry: LibraryEntry
    @State private var directors: [CastMember] = []
    @State private var creditsLoading = true

    var body: some View {
        VStack(spacing: 6) {
            // Every row reserves its height (two title lines, a pill row), so no poster moves the block.
            ZStack {
                Text(verbatim: "A\nA").scaledFont(size: 19, weight: .semibold).hidden()
                Text(verbatim: entry.year.map { "\(entry.title) (\($0))" } ?? entry.title)
                    .scaledFont(size: 19, weight: .semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            ZStack {
                if let sizer = RatingChip.plain(1) { RatingPill(chip: sizer).hidden() }
                HStack(spacing: 5) {
                    ForEach(chips, id: \.label) { RatingPill(chip: $0) }
                }
            }
            // The hidden line pins the row to the credit's own height, so the skeleton swap can't move anything.
            ZStack {
                Text(verbatim: " ").scaledFont(size: 11).hidden()
                if creditsLoading {
                    SkeletonBar(width: 150, height: 11)
                } else {
                    DirectedByLine(people: directors,
                                   labelKey: entry.source == .sonarr ? "detail.createdBy.label" : "detail.directedBy.label")
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: entry.id) {
            // Skipped while flicking past: only a poster the scroll rests on asks for credits.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let credits = entry.source == .sonarr
                ? await CastProvider.seriesCredits(tmdbId: nil, tvdbId: entry.externalId, configStore: configStore)
                : await CastProvider.movieCredits(radarrMovieId: entry.arrId, tmdbId: entry.externalId, configStore: configStore)
            guard !Task.isCancelled else { return }
            directors = credits.directors
            creditsLoading = false
        }
    }

    /// Unlinked, like the Library tooltip: the chips sit over the scroll surface.
    private var chips: [RatingChip] {
        switch entry.source {
        case .radarr, .whisparr:
            [
                entry.ratingImdb.flatMap { RatingChip.imdb($0) },
                entry.ratingTmdb.flatMap { RatingChip.tmdb($0) },
                entry.ratingRt.flatMap { RatingChip.rottenTomatoes($0) },
                entry.ratingMetacritic.flatMap { RatingChip.metacritic($0) },
            ].compactMap { $0 }
        case .sonarr:
            [entry.ratingArr.flatMap { RatingChip.tvdb($0) }].compactMap { $0 }
        case .lidarr:
            []
        }
    }
}

extension Int {
    /// This index in a library of `count` that repeats forever.
    func shelfWrapped(into count: Int) -> Int {
        count > 0 ? (self % count + count) % count : 0
    }
}

nonisolated private struct ShelfSnap: ScrollTargetBehavior {
    let pitch: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = (target.rect.origin.x / pitch).rounded() * pitch
    }
}
