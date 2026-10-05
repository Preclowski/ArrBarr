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
/// event never re-evaluates the Shelf's body; the TimelineView alone redraws, and only while `active` (or for
/// Warp's idle wave).
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
            // Short: the library strips come back with the clean frame, and nobody waits long for them.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.active = false
        }
    }

    /// A cover sits on the hero slot. A finger resting mid-scroll also stops the events, between two covers.
    var isOnCover: Bool { abs(position - position.rounded()) < 0.02 }

    /// Posters per second.
    func velocity(at now: CFTimeInterval) -> Double {
        // The frame drawn as the tick pauses must be the clean one; speed effects would freeze mid-glitch.
        active ? velocity * exp(-(now - stamp) * 7) : 0
    }
}

/// The Roulette's place for the app's run. The panel rebuilds its content on every open and tab switch, which
/// reshuffled the library and sent the Roulette back to its first title.
final class ShelfSession {
    static let shared = ShelfSession()

    var filter: ShelfFilter?
    var collection: ShelfCollection = .library
    /// The title on the hero slot, per collection and source.
    var centred: [String: String] = [:]
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

    /// `prefetch` that returns once the covers are in, so a new set appears whole instead of filling in.
    func warm(_ entries: [LibraryEntry], around center: Int, apiKey: String) async {
        guard !entries.isEmpty else { return }
        let entry = { (k: Int) in entries[(center + k).shelfWrapped(into: entries.count)] }
        await withTaskGroup(of: Void.self) { group in
            for k in [0] + (1...20).flatMap({ [$0, -$0] }) {
                let e = entry(k)
                group.addTask { await self.load(e, tier: abs(k) <= 4 ? .card : .icon, apiKey: apiKey) }
            }
        }
    }

    private func fetch(_ entry: LibraryEntry, tier: PosterTier, apiKey: String) {
        Task { await load(entry, tier: tier, apiKey: apiKey) }
    }

    private func load(_ entry: LibraryEntry, tier: PosterTier, apiKey: String) async {
        let key = "\(tier.rawValue)|\(entry.id)"
        let have = tier == .card ? large[entry.id] : small[entry.id]
        guard have == nil, !inFlight.contains(key), let url = entry.posterURL else { return }
        inFlight.insert(key)
        let auth = entry.posterRequiresAuth ? apiKey : nil
        let image = await PosterStore.shared.image(for: url, tier: tier, apiKey: auth)
        inFlight.remove(key)
        guard let image else { return }
        if tier == .card { large[entry.id] = image } else { small[entry.id] = image }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bottom control grown into its panel, if any.
    @State private var openControl: ShelfControlKind?
    @State private var filter: ShelfFilter
    @State private var collection: ShelfCollection
    /// The scroll has been put on this set's remembered title; until then the hero is not recorded.
    @State private var placed = false
    @State private var remote = ShelfRemoteLists()
    /// A TMDB set is being fetched and its covers loaded; the stage stays on the spinner meanwhile.
    @State private var warming = false
    /// Sources whose first load in this Shelf has finished; until then every empty state is a loading screen.
    @State private var settled: Set<QueueItem.Source> = []
    /// Set once the first centre poster has landed (or after a timeout), so the opening frame is never placeholders.
    @State private var revealed = false

    private static let modeKey = "shelfMode"

    /// `initialMode` is the debug harness's; otherwise the last mode picked.
    init(isObscured: Bool, initialMode: ShelfMode? = nil, initialPosition: Double? = nil, onClose: (() -> Void)? = nil) {
        self.isObscured = isObscured
        self.initialPosition = initialPosition
        self.onClose = onClose
        let saved = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(ShelfMode.init(rawValue:))
        _mode = State(initialValue: initialMode ?? saved ?? .warp)
        _filter = State(initialValue: ShelfSession.shared.filter ?? ShelfFilter(source: .radarr))
        _collection = State(initialValue: ShelfSession.shared.collection)
    }

    private var session: ShelfSession { .shared }
    private var sessionKey: String { "\(collection.rawValue)|\(source.rawValue)" }

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

    private var remoteKey: ShelfRemoteLists.Key? {
        collection.isRemote ? .init(collection: collection, source: source) : nil
    }

    private var availableCollections: [ShelfCollection] {
        ShelfCollection.available(for: source, tmdbConfigured: !configStore.tmdbApiKey.isEmpty)
    }

    private var entries: [LibraryEntry] {
        let f = filter
        if let remoteKey {
            // A few dozen titles: sorted per pass, no cache needed.
            let all = (remote.items[remoteKey] ?? []).map(\.entry).sorted(by: f.areInIncreasingOrder)
            return f.isNarrowed ? all.filter(f.matches) : all
        }
        let sorted = library.sorted(f.source, cacheKey: f.sortKey, using: f.areInIncreasingOrder)
        guard f.isNarrowed else { return sorted }
        return library.visible(f.source, cacheKey: f.key, from: sorted, where: f.matches)
    }

    private var centerIndex: Int { motion.center.shelfWrapped(into: entries.count) }

    /// Warp's edges wave at rest too; paused, any body pass (a hover) redrew the wave a jump further on.
    private var ticking: Bool {
        !isObscured && (motion.active || (mode == .warp && !reduceMotion))
    }

    private func sceneReady(_ entries: [LibraryEntry]) -> Bool {
        !warming && (revealed || (!entries.isEmpty && posters.image(for: entries[centerIndex].id) != nil))
    }

    var body: some View {
        let entries = entries
        GeometryReader { geo in
            ZStack {
                if sceneReady(entries) {
                // The idle wave is slow: 15 fps carries it, and every frame also re-samples the glass over the stage.
                TimelineView(.animation(minimumInterval: motion.active ? nil : 1.0 / 15, paused: !ticking)) { timeline in
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
                ZStack {
                    if entries.indices.contains(centerIndex), sceneReady(entries), !motion.active, motion.isOnCover,
                       openControl == nil, let mark = entries[centerIndex].libraryMark {
                        heroStrip(mark, size: geo.size)
                            .transition(.opacity)
                    }
                }
                // Gone at once when the Shelf moves, eased in once it settles.
                .animation(motion.active ? nil : .easeOut(duration: 0.2), value: motion.active)
                if entries.isEmpty && !warming {
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
        .task(id: remoteKey) {
            guard let remoteKey else { warming = false; return }
            warming = true
            await remote.load(remoteKey, configStore: configStore)
            guard !Task.isCancelled else { return }
            // `self.`: the body's `entries` was taken before the list arrived.
            let set = self.entries
            // Warmed around the title the recentre lands on.
            await posters.warm(set, around: remembered(in: set), apiKey: apiKey)
            guard !Task.isCancelled else { return }
            recenter(set, restoring: true)
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            warming = false
        }
        .onChange(of: mode) { _, new in
            UserDefaults.standard.set(new.rawValue, forKey: Self.modeKey)
        }
        .onChange(of: availableCollections) { _, available in
            if !available.contains(collection) { collection = available.contains(.popular) ? .popular : .library }
        }
        .onChange(of: collection) { _, new in
            session.collection = new
            placed = false
            // A genre or sort from the other set could empty or scramble this one.
            filter.clearNarrowing()
            if !ShelfView.sortModes(for: new, source: source).contains(filter.sort), filter.shuffleSeed == nil {
                filter.shuffleSeed = Int.random(in: 1...Int(Int32.max))
            }
            if !new.isRemote { recenter(entries, restoring: true) }
        }
        .onChange(of: filter) { old, new in
            session.filter = new
            placed = false
            // Another source keeps its own place; a new sort or filter starts from the top.
            var sameOrder = old
            sameOrder.source = new.source
            recenter(entries, restoring: sameOrder == new)
            posters.prefetch(entries, around: 0, apiKey: apiKey)
        }
        .onChange(of: centerIndex, initial: true) { _, center in
            posters.prefetch(entries, around: center, apiKey: apiKey)
            if placed, entries.indices.contains(center) { session.centred[sessionKey] = entries[center].id }
        }
        .onChange(of: entries.count) { old, _ in
            // Only the first load recentres; a background refresh that adds a title must not throw you back.
            if old == 0 { recenter(entries, restoring: true) }
            posters.prefetch(entries, around: old == 0 ? remembered(in: entries) : centerIndex, apiKey: apiKey)
        }
        .task(id: entries.count) {
            guard let initialPosition, !entries.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            scroll.scrollTo(x: CGFloat(Double(Self.home(entries.count)) + initialPosition) * Self.pitch)
        }
    }

    // MARK: - Layers

    /// The selected poster's library strip, drawn over the chrome's shade (it would dim it with the cover) and
    /// outside the scene's shaders; at rest every mode leaves that poster on this rect.
    private func heroStrip(_ mark: LibraryMark, size: CGSize) -> some View {
        let w = ShelfScene.heroWidth(for: size)
        return mark.strip(in: PosterBottomEdge(thickness: min(3, w * 0.02), cornerRadius: w * 0.04))
            .frame(width: w, height: w * 1.5)
            .position(ShelfScene.heroCenter(in: size))
            .allowsHitTesting(false)
    }

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
                ShelfInfo(entry: entries[centerIndex], tmdbId: remoteItem(entries[centerIndex])?.tmdbId)
                    .padding(.horizontal, 20)
                    // An open panel stands where the info block is.
                    .opacity(openControl == nil ? 1 : 0)
                    .offset(y: openControl == nil ? 0 : 6)
                    .id(entries[centerIndex].id)
                    .transition(.opacity)
            }
            controls(entries)
                .padding(.top, 12)
                .padding(.bottom, 14)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .frame(height: 200)
                .allowsHitTesting(false)
        }
        .background {
            // Deeper while a panel is open, so its glass reads over bright covers. Absent otherwise: one more
            // full-screen layer over the shader scene on every frame.
            if openControl != nil {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: UnitPoint(x: 0.5, y: 0.3), endPoint: .bottom)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: centerIndex)
        .animation(.easeOut(duration: 0.25), value: openControl)
    }

    /// Collection, filter and mode, each a glass button that grows into its panel. The row keeps the buttons'
    /// height; a panel floats up over the info block.
    private func controls(_ entries: [LibraryEntry]) -> some View {
        Color.clear
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomLeading) {
                if availableCollections.count > 1 {
                    ShelfExpandingControl(kind: .collection, open: $openControl, alignment: .bottomLeading,
                                          label: Text(collection.title, bundle: .module)) {
                        Image(systemName: collection.symbol)
                    } panel: {
                        ShelfCollectionPanel(collection: $collection, available: availableCollections,
                                             libraryCount: library.entries[source]?.count)
                    }
                    .padding(.leading, 12)
                }
            }
            .overlay(alignment: .bottom) {
                ShelfExpandingControl(kind: .filter, open: $openControl, alignment: .bottom,
                                      label: Text("common.filter.button", bundle: .module)) {
                    Image(systemName: filter.isNarrowed ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                } panel: {
                    ShelfFilterPanel(filter: $filter, sources: sources,
                                     library: remoteKey.map { (remote.items[$0] ?? []).map(\.entry) } ?? library.entries[source] ?? [],
                                     sortModes: Self.sortModes(for: collection, source: source),
                                     watchStateKnown: !collection.isRemote && configStore.mediaServer.isConfigured,
                                     showsLibraryToggle: collection.isRemote)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ShelfExpandingControl(kind: .mode, open: $openControl, alignment: .bottomTrailing,
                                      label: Text(mode.title, bundle: .module)) {
                    Image(systemName: mode.symbol)
                } panel: {
                    ShelfModePanel(mode: $mode, entries: entries, posters: posters, center: motion.center)
                }
                .padding(.trailing, 12)
            }
    }

    /// TMDB lists have no dates added, sizes or arr ratings.
    static func sortModes(for collection: ShelfCollection, source: QueueItem.Source) -> [SortMode] {
        collection.isRemote ? [.title, .releaseDate, .tmdb] : SortMode.available(for: source)
    }

    private func remoteItem(_ entry: LibraryEntry) -> ShelfRemoteItem? {
        remoteKey.flatMap { remote.items[$0]?.first { $0.entry.id == entry.id } }
    }

    private var emptyState: some View {
        Group {
            if let remoteKey {
                if remote.failed.contains(remoteKey) {
                    Text("library.error.title", bundle: .module).foregroundStyle(.secondary)
                } else if remote.items[remoteKey] == nil {
                    LoadingStateView()
                } else if filter.isNarrowed {
                    Text("Every result is filtered out.", bundle: .module).foregroundStyle(.secondary)
                } else {
                    Text("shelf.empty", bundle: .module).foregroundStyle(.secondary)
                }
            } else if !settled.contains(source) || library.loading.contains(source) || library.entries[source] == nil {
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

    /// The content width changes in the same update, so the jump waits a beat for layout. `restoring` lands on
    /// the title this collection last showed, when it is still in the set; otherwise on the first.
    private func recenter(_ entries: [LibraryEntry], restoring: Bool) {
        guard !entries.isEmpty else { return }
        let index = restoring ? remembered(in: entries) : 0
        let x = CGFloat(Self.home(entries.count) + index) * Self.pitch
        let key = sessionKey
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            scroll.scrollTo(x: x)
            session.centred[key] = entries[index].id
            placed = true
        }
    }

    private func remembered(in entries: [LibraryEntry]) -> Int {
        session.centred[sessionKey].flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
    }

    /// The centre poster opens its detail; a tap either side steps toward it.
    private func tap(atContentX x: CGFloat, size: CGSize, entries: [LibraryEntry]) {
        // A tap beside an open panel closes it (iOS has no pointer to leave it with).
        if openControl != nil { openControl = nil; return }
        let screenX = x - CGFloat(motion.position) * Self.pitch
        let half = ShelfScene.heroWidth(for: size) / 2
        if screenX < size.width / 2 - half { step(-1, count: entries.count); return }
        if screenX > size.width / 2 + half { step(1, count: entries.count); return }
        guard entries.indices.contains(centerIndex) else { return }
        let entry = entries[centerIndex]
        if let item = remoteItem(entry), item.result.inLibraryArrId == nil {
            SearchAddRequest.post(item.result)
            return
        }
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
    /// Set for TMDB lists: their series carry no tvdbId, and their films may not be in Radarr.
    var tmdbId: Int? = nil
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
                ? await CastProvider.seriesCredits(tmdbId: tmdbId, tvdbId: entry.externalId, configStore: configStore)
                : await CastProvider.movieCredits(radarrMovieId: entry.arrId > 0 ? entry.arrId : nil,
                                                  tmdbId: entry.externalId, configStore: configStore)
            guard !Task.isCancelled else { return }
            directors = credits.directors
            creditsLoading = false
        }
    }

    /// Linked like the detail hero's. No ids beyond the arr's own, so IMDb, RT and Metacritic open a title search.
    private var chips: [RatingChip] {
        let title = entry.title
        switch entry.source {
        case .radarr, .whisparr:
            return [
                entry.ratingImdb.flatMap { RatingChip.imdb($0, linkTitle: title) },
                entry.ratingTmdb.flatMap { RatingChip.tmdb($0, linkTitle: title, tmdbId: tmdbId ?? entry.externalId) },
                entry.ratingRt.flatMap { RatingChip.rottenTomatoes($0, linkTitle: title) },
                entry.ratingMetacritic.flatMap { RatingChip.metacritic($0, linkTitle: title) },
            ].compactMap { $0 }
        case .sonarr:
            // `RatingChip.tmdb` links a film page; a series' TMDB chip searches by title instead.
            return [
                entry.ratingArr.flatMap { RatingChip.tvdb($0, linkTitle: title, tvdbId: entry.externalId) },
                entry.ratingTmdb.flatMap { RatingChip.tmdb($0, linkTitle: title) },
            ].compactMap { $0 }
        case .lidarr:
            return []
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
