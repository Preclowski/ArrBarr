import SwiftUI
import SwiftData
import MediaKit

/// Apple-TV-style home: a big hero backdrop followed by shelves.
struct HomeView: View {
    @EnvironmentObject private var config: TonightConfig
    @Query(sort: \WatchList.createdAt) private var lists: [WatchList]

    struct Content {
        var heroItems: [MediaItem] = []
        /// Shelves in the user's configured order. `.myLists` carries no
        /// items — it stands in for the watchlists rendered from SwiftData.
        var shelves: [(kind: HomeSectionKind, items: [MediaItem])] = []
    }

    @State private var content: Content?
    @State private var error: String?

    var body: some View {
        Group {
            if let content {
                // The sidebar floats over this column as a leading
                // safe-area inset: the hero ignores it and runs the full
                // width of the window, under the glass, while everything
                // else steps back out by the width it swallowed.
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        if !content.heroItems.isEmpty {
                            HeroCarousel(items: content.heroItems)
                        }
                        VStack(alignment: .leading, spacing: 30) {
                            ForEach(content.shelves, id: \.kind) { shelf in
                                if shelf.kind == .myLists {
                                    // The user's own lists, surfaced right on
                                    // Home — live from SwiftData, so they are
                                    // rendered here rather than baked into
                                    // the loaded content.
                                    ForEach(lists.filter { !$0.titles.isEmpty }) { list in
                                        Shelf(title: list.name,
                                              items: list.titles
                                                  .sorted { $0.addedAt > $1.addedAt }
                                                  .map(\.mediaItem))
                                    }
                                } else {
                                    Shelf(title: shelf.kind.title,
                                          items: shelf.items,
                                          wide: shelf.kind.wide)
                                }
                            }
                        }
                        .clearOfSidebar(!content.heroItems.isEmpty)
                    }
                    .padding(.bottom, 40)
                }
                .ignoresSafeArea(edges: content.heroItems.isEmpty ? [] : [.top, .leading])
                // Ignoring the safe area is not enough on its own: the scroll
                // view still reserves the toolbar's height as a content margin,
                // which left an empty band above the hero.
                .contentMargins(.top, 0, for: .scrollContent)
            } else if let error {
                QuietMessage(systemImage: "wifi.slash",
                             title: String(localized: "Can't reach TMDB", bundle: .module),
                             subtitle: error,
                             action: (String(localized: "Retry", bundle: .module),
                                      { Task { await load() } }))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Re-load whenever the key OR the Home layout changes, so Settings
        // edits show up the next time Home is on screen.
        .task(id: layoutID) { await load() }
    }

    /// Identity of everything `load()` depends on.
    private var layoutID: String {
        ([config.tmdbApiKey, config.homeHero.rawValue]
            + config.visibleHomeSections.map(\.rawValue)).joined(separator: "|")
    }

    private func load() async {
        error = nil
        let region = config.watchRegion
        let sections = config.visibleHomeSections
        let hero = config.homeHero
        do {
            async let heroFetch = heroItems(hero, region: region)
            // One query per configured shelf, all in flight together. Which
            // source answers each one is the graph's business — a shelf like
            // "recently added" will come from the media server without this
            // view learning anything new.
            let shelves = try await withThrowingTaskGroup(of: (Int, HomeSectionKind, [MediaItem]).self) { group in
                for (index, kind) in sections.enumerated() {
                    guard var query = kind.query else {
                        group.addTask { (index, kind, []) }
                        continue
                    }
                    query.region = region
                    group.addTask {
                        let page = try await MediaStack.shared.titles(query, enrich: .availability)
                        return (index, kind, page.items)
                    }
                }
                var collected: [(Int, HomeSectionKind, [MediaItem])] = []
                for try await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }
            }
            var result = Content()
            result.heroItems = try await heroFetch
            result.shelves = shelves
                // A shelf that came back empty is noise; My Lists survives
                // because its content lives in SwiftData, not in `items`.
                .filter { $0.1 == .myLists || !$0.2.isEmpty }
                .map { (kind: $0.1, items: $0.2) }
            content = result
        } catch {
            if content == nil { self.error = shortDescription(of: error) }
        }
    }

    /// The marquee roster: trending movies, trending series, or the two
    /// interleaved so the mix alternates instead of clumping.
    private func heroItems(_ kind: HomeHeroKind, region: String) async throws -> [MediaItem] {
        func withArt(_ items: [MediaItem]) -> [MediaItem] { items.filter { $0.backdropPath != nil } }
        @Sendable func trending(_ kind: MediaKind) async throws -> [MediaItem] {
            try await MediaStack.shared.titles(
                MediaCatalogQuery(.trending(window: .week), kind: kind, region: region),
                enrich: .availability).items
        }
        switch kind {
        case .movies:
            return Array(withArt(try await trending(.movie)).prefix(8))
        case .series:
            return Array(withArt(try await trending(.series)).prefix(8))
        case .mix:
            async let movies = trending(.movie)
            async let series = trending(.series)
            let (m, t) = (withArt(try await movies), withArt(try await series))
            var mixed: [MediaItem] = []
            for index in 0..<max(m.count, t.count) {
                if index < m.count { mixed.append(m[index]) }
                if index < t.count { mixed.append(t[index]) }
            }
            return Array(mixed.prefix(8))
        }
    }
}

/// Apple-TV-style marquee: trending movies in a full-width paging carousel
/// with page dots and a slow auto-advance (paused while hovered).
struct HeroCarousel: View {
    let items: [MediaItem]
    @EnvironmentObject private var config: TonightConfig
    @State private var currentIndex: Int?
    @State private var hovering = false
    /// Genres, tagline and the title's own logo for the slide in view. The
    /// carousel's own payload has none of them — one details call per slide,
    /// kept for the whole visit so paging back is free.
    @State private var details: [String: TitleDetails] = [:]
    /// IMDb / Rotten Tomatoes for the slide in view. TMDB's own score rides
    /// along with the trending payload; every other service is a field the
    /// graph has to be asked for, exactly as the detail page asks.
    @State private var ratings: [String: MediaKit.Ratings] = [:]
    private let autoAdvance = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HeroSlide(item: item, siblings: items, index: index)
                        .containerRelativeFrame(.horizontal)
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentIndex)
        // Bottom-left, exactly like a title page's header: the two heros are
        // the same picture at the same height with the same copy on it.
        .overlay(alignment: .bottomLeading) { caption }
        .overlay(alignment: .bottom) {
            if items.count > 1 { pageDots }
        }
        .overlay(alignment: .leading) {
            if hovering && items.count > 1 {
                PagingChevron(direction: .previous, help: title(offset: -1)) { advance(by: -1) }
                    .clearOfSidebar()
            }
        }
        .overlay(alignment: .trailing) {
            if hovering && items.count > 1 {
                PagingChevron(direction: .next, help: title(offset: 1)) { advance(by: 1) }
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onReceive(autoAdvance) { _ in
            guard !hovering, items.count > 1 else { return }
            advance(by: 1)
        }
    }

    /// The slide in view, written in the detail page's running order: title,
    /// claim, facts, scores. Laid out against the carousel, so it sits at a
    /// fixed inset from the window edge no matter where the scroll offset
    /// happens to be.
    @ViewBuilder
    private var caption: some View {
        if let item = items.indices.contains(currentIndex ?? 0) ? items[currentIndex ?? 0] : items.first {
            let detail = details[item.id]
            // The same box the title page reserves under its logo: claim,
            // facts and scores live in the top of it, the space a title page
            // fills with library marks and buttons stays empty.
            HeroCopyBlock(item: item, fallbackLogo: detail?.logoURL,
                          pending: detail == nil, tagline: detail?.tagline,
                          taglineMaxWidth: 620) {
                // Same running order as the detail page: the facts, then the
                // scores on their own line under them.
                HStack(spacing: 10) {
                    Text(metaLine(item, detail))
                        .font(.callout.weight(.medium))
                        .opacity(0.92)
                    if detail == nil { SkeletonBar(width: 180) }
                }
                ScoreStrip(scores: ServiceScore.row(tmdb: item.rating, votes: item.voteCount,
                                                    tmdbURL: detail?.tmdbURL,
                                                    external: ratings[item.id],
                                                    imdbURL: detail?.imdbURL)
                               .filter { $0.value != nil },
                           style: .inline, showsVotes: true, mono: true)
                    .animation(.easeOut(duration: 0.25), value: ratings[item.id]?.value(for: .imdb))
            }
            .foregroundStyle(.white)
            .heroCopyInsets()
            .allowsHitTesting(false) // the slide underneath is the link
            .animation(.easeOut(duration: 0.25), value: currentIndex)
            .task(id: item.id) { await loadDetail(item) }
        }
    }

    /// "2026 · Movie · 2h 25min · Thriller · Crime · Polska" — the detail
    /// page's facts line, with the kind spelled out because a marquee mixes
    /// films and shows.
    private func metaLine(_ item: MediaItem, _ detail: TitleDetails?) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        parts.append(item.type == .movie
            ? String(localized: "Movie", bundle: .module)
            : String(localized: "TV Series", bundle: .module))
        if let runtime = detail?.runtimeMinutes, runtime > 0 {
            parts.append(Duration.seconds(runtime * 60)
                .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        if let seasons = detail?.seasonCount {
            parts.append(String(format: String(localized: "%d seasons", bundle: .module), seasons))
        }
        parts.append(contentsOf: (detail?.genres ?? []).prefix(3))
        parts.append(contentsOf: detail?.countryNames ?? [])
        return parts.joined(separator: " · ")
    }

    private func loadDetail(_ item: MediaItem) async {
        guard !config.tmdbApiKey.isEmpty else { return }
        // Ask for the scores the same way the detail page does — one graph
        // fetch per slide, answered from MediaKit's cache once the title has
        // been opened, and kept for the rest of the visit either way.
        if ratings[item.id] == nil {
            Task {
                let snapshot = await MediaStack.shared.snapshot(for: item, fields: [.ratings])
                guard let gathered = snapshot.ratings else { return }
                ratings[item.id] = gathered
            }
        }
        guard details[item.id] == nil else { return }
        let service = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        guard let loaded = try? await service.details(for: item) else { return }
        withAnimation(.easeOut(duration: 0.2)) { details[item.id] = loaded }
    }

    /// Title the chevron would page to, for its tooltip.
    private func title(offset: Int) -> String {
        guard !items.isEmpty else { return "" }
        let next = (((currentIndex ?? 0) + offset) + items.count) % items.count
        return items[next].displayTitle
    }

    private func advance(by delta: Int) {
        withAnimation(.easeInOut(duration: 0.6)) {
            currentIndex = (((currentIndex ?? 0) + delta) + items.count) % items.count
        }
    }

    /// Bare Apple-TV dots — no plate, just white circles over the scrim.
    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(items.indices, id: \.self) { index in
                Button {
                    withAnimation(.easeInOut(duration: 0.5)) { currentIndex = index }
                } label: {
                    Circle()
                        .fill(.white.opacity(index == (currentIndex ?? 0) ? 0.95 : 0.35))
                        .frame(width: 7, height: 7)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .contentShape(Circle().inset(by: -3))
                }
                .buttonStyle(.plain)
            }
        }
        // Same number, a different intent: the dots are centred over the
        // region the viewer actually sees, not held clear of the glass.
        .clearOfSidebar()
        .padding(.bottom, 18)
        .animation(.easeInOut(duration: 0.25), value: currentIndex)
    }
}

/// One marquee slide: edge-to-edge backdrop under the shared scrim, exactly
/// like the detail header, dissolving into the page at the bottom.
///
/// Art only. The title used to live in here, and rode the scroll offset with
/// it: the paging container is the width of the safe area while the art
/// spans the whole window, so every auto-advance left the carousel a few
/// points off a page boundary and the copy crept toward the sidebar. The
/// copy now hangs off the carousel, whose frame does not move.
private struct HeroSlide: View {
    let item: MediaItem
    let siblings: [MediaItem]
    let index: Int

    var body: some View {
        NavigationLink(value: TitleSelection(items: siblings, index: index)) {
            // The detail header's height exactly: two heros of different
            // sizes made the same artwork jump the moment a slide was opened.
            HeroBanner(url: item.displayBackdropURL, height: 620)
                .overlay(BackdropScrim())
                .heroFade()
        }
        .buttonStyle(.plain)
    }
}

func shortDescription(of error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}


