import SwiftUI
import MediaKit

/// Movies / Series browser: an endless poster grid with the advanced-filter
/// panel in its header. Discover's genre and decade tiles reuse it with that
/// genre — or those years — pinned, so every way into TMDB lands on the same
/// library view.
struct BrowseView: View {
    let type: MediaType
    /// What the page is pinned to — the genre or the decade a Discover tile
    /// pushed it with. It stays put through Reset and is named in the header
    /// rather than drawn as a filter token.
    private let preset: FilterPreset
    private let titleOverride: String?

    @EnvironmentObject private var config: TonightConfig
    @EnvironmentObject private var externalLibrary: ExternalLibraryStore

    @State private var filter: DiscoverFilter
    @State private var items: [MediaItem] = []
    @State private var page = 1
    @State private var exhausted = false
    @State private var loading = false
    @State private var error: String?
    /// Layout, poster cut and — the part this page also queries with — the
    /// sort. The menu in the header writes here; the filter follows.
    @ObservedObject private var options: MediaCollectionOptions

    init(type: MediaType) {
        self.init(type: type, preset: .none, title: nil)
    }

    init(genre: GenreRef) {
        self.init(type: genre.type,
                  preset: FilterPreset(genreIds: [genre.id]),
                  title: genre.displayName)
    }

    init(decade: DecadeRef) {
        self.init(type: decade.type,
                  preset: FilterPreset(years: decade.decade.years),
                  title: decade.displayName)
    }

    /// The one initializer: a kind, what the page is pinned to, and what the
    /// header calls it. The pin IS the starting filter — there is no second
    /// place where a page's own genre or years are set.
    private init(type: MediaType, preset: FilterPreset, title: String?) {
        self.type = type
        self.preset = preset
        self.titleOverride = title
        let options = MediaCollectionOptions.shared(.browse(type))
        self.options = options
        var filter = DiscoverFilter(type: type)
        filter.sort = options.sort.discover ?? .popularity
        _filter = State(initialValue: preset.applied(to: filter))
    }

    /// The graph already applied the library-presence filter — it is the only
    /// place that knows what the user owns, and doing it there means paging
    /// keeps working instead of the page arriving half empty.
    private var displayItems: [MediaItem] { items }

    var body: some View {
        grid
            // Pushed from a genre card: the app's own back control, in the
            // header strip, replaces the toolbar's.
            .modifier(PushedPage(active: isPushed))
            .task(id: taskKey) { await load(reset: true) }
            // One sort, named in one place: the menu owns it, the query
            // follows it. It used to be a caption here, a chip row in the
            // panel and the table's own private order, all at once.
            .onChange(of: options.sort) { _, new in
                filter.sort = new.discover ?? .popularity
            }
    }

    private var grid: some View {
        MediaCollectionView(.browse(type),
                            items: displayItems,
                            loading: loading,
                            onReachEnd: { loadMore() })
        .overlay {
            if displayItems.isEmpty {
                if loading {
                    ProgressView()
                } else if let error {
                    QuietMessage(systemImage: "wifi.slash",
                                 title: String(localized: "Can't reach TMDB", bundle: .module),
                                 subtitle: error,
                                 action: (String(localized: "Retry", bundle: .module), { reload() }))
                } else {
                    emptyMessage
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    /// What "nothing here" means depends on which scope asked. In Library it
    /// is a shelf that does not have this; in Discover it is the happy case.
    private var emptyMessage: some View {
        switch filter.libraryPresence {
        case .owned:
            return QuietMessage(systemImage: "internaldrive",
                                title: String(localized: "Nothing in your library matches", bundle: .module),
                                subtitle: String(localized: "Switch to All to see everything TMDB has.", bundle: .module))
        case .notOwned:
            return QuietMessage(systemImage: "checkmark.circle",
                                title: String(localized: "You already have everything here", bundle: .module),
                                subtitle: String(localized: "Nice. Try another genre or loosen the filters.", bundle: .module))
        case .all:
            return QuietMessage(systemImage: "line.3.horizontal.decrease.circle",
                                title: String(localized: "Nothing matches", bundle: .module),
                                subtitle: String(localized: "Try loosening the filters.", bundle: .module))
        }
    }

    // MARK: - Chrome

    /// The grid's own header strip: what the filter is currently doing, and
    /// the one control that opens the inspector.
    /// Pushed here from a Discover tile — that page owns a back control and
    /// sits below the window's own top inset.
    private var isPushed: Bool { titleOverride != nil }

    /// What a deck dealt from this page is called in the Quiz: the pin the
    /// page is named after, or the section itself.
    private var quizDeckName: String {
        titleOverride ?? (type == .movie
            ? String(localized: "Movies", bundle: .module)
            : String(localized: "Series", bundle: .module))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let titleOverride {
                    BackButton()
                    Text(titleOverride).font(.headline)
                }
                // Leading, because it is the page's scope rather than one of
                // its controls: what you are looking at, before how.
                OwnedOnlyToggle(presence: $filter.libraryPresence)

                Spacer(minLength: 0)

                QuizThisControl(options: options, items: displayItems,
                                name: quizDeckName)
                CollectionSortMenu(options: options)
                MediaLayoutPicker(options: options)
                FiltersControl(filter: $filter, type: type,
                               resultCount: displayItems.count,
                               preset: preset)
            }
            // Only when something is on — the chrome grows to fit what it
            // has to say and shrinks back when it has nothing.
            ActiveFilterRow(filter: $filter, type: type, preset: preset)
        }
        .padding(.horizontal, 28)
        .padding(.top, pageChromeTop)
        .padding(.bottom, 10)
        .background(.bar)
        .animation(.easeOut(duration: 0.18), value: filter.activeCount)
    }

    // MARK: - Loading

    /// Reload whenever the filter or key changes.
    private var taskKey: String {
        "\(config.tmdbApiKey.hashValue)-\(filter.hashValue)"
    }

    private func reload() {
        Task { await load(reset: true) }
    }

    private func loadMore() {
        guard !loading, !exhausted else { return }
        Task { await load(reset: false) }
    }

    private func load(reset: Bool) async {
        if reset {
            page = 1
            exhausted = false
            error = nil
        }
        loading = true
        defer { loading = false }
        do {
            // Ask the layer for a page of titles, not TMDB for a page of
            // JSON: which source answers, what it costs and whether the
            // library filter can be applied is the graph's business.
            let result = try await MediaStack.shared.titles(
                filter.catalogQuery(page: page, region: config.watchRegion),
                enrich: .availability)
            if reset { items = result.items } else {
                let known = Set(items.map(\.id))
                items += result.items.filter { !known.contains($0.id) }
            }
            if result.items.isEmpty && !result.hasMore { exhausted = true } else { page += 1 }
            // A presence filter can empty a whole page — keep pulling until
            // the grid has something to show (bounded by the page counter).
            if !exhausted, filter.libraryPresence != .all, items.count < 24, page <= 15 {
                await load(reset: false)
            }
        } catch {
            if items.isEmpty { self.error = shortDescription(of: error) }
        }
    }
}
