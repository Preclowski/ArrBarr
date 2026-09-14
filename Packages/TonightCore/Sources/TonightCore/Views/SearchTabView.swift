import SwiftUI

/// Navigation payload for a full search category page.
struct SearchCategoryRef: Hashable {
    let query: String
    let category: TMDBService.SearchCategory
}

/// The search page: takes over the detail column while a query is active,
/// says out loud what it searched for, and previews up to 10 hits per
/// category — the category headline opens the full, paginated results.
struct SearchResultsView: View {
    let query: String
    @EnvironmentObject private var config: TonightConfig
    @State private var results = SearchResults()
    @State private var searching = false

    private let previewLimit = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(String(format: String(localized: "Results for “%@”", bundle: .module),
                            trimmedQuery))
                    .font(.title.weight(.bold))
                    .padding(.horizontal, 28)
                    .padding(.top, 16)

                if !results.people.isEmpty {
                    peopleSection
                }
                if !results.movies.isEmpty {
                    mediaSection("Movies", category: .movies, items: results.movies)
                }
                if !results.shows.isEmpty {
                    mediaSection("Series", category: .series, items: results.shows)
                }
            }
            .padding(.bottom, 40)
        }
        .overlay {
            if results.isEmpty {
                if searching {
                    ProgressView()
                } else {
                    QuietMessage(systemImage: "questionmark.circle",
                                 title: String(localized: "No results", bundle: .module),
                                 subtitle: nil)
                }
            }
        }
        .task(id: query) {
            guard trimmedQuery.count >= 2 else {
                results = SearchResults()
                return
            }
            searching = true
            defer { searching = false }
            try? await Task.sleep(for: .milliseconds(250)) // debounce
            guard !Task.isCancelled else { return }
            let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
            guard let found = try? await tmdb.searchAll(trimmedQuery) else { return }
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// "Movies ›" — the headline is the way into the full category.
    private func sectionHeader(_ key: LocalizedStringKey,
                               category: TMDBService.SearchCategory) -> some View {
        NavigationLink(value: SearchCategoryRef(query: trimmedQuery, category: category)) {
            HStack(spacing: 5) {
                Text(key, bundle: .module)
                    .font(.title3.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .padding(.horizontal, 28)
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("People", category: .people)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(results.people.prefix(previewLimit)) { person in
                        PersonCell(person: person)
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }

    private func mediaSection(_ key: LocalizedStringKey,
                              category: TMDBService.SearchCategory,
                              items: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(key, category: category)
            PosterGrid(items: Array(items.prefix(previewLimit)))
        }
    }
}

/// Full, endlessly-paginated results for one search category.
struct SearchCategoryView: View {
    let ref: SearchCategoryRef
    @EnvironmentObject private var config: TonightConfig

    @State private var items: [MediaItem] = []
    @State private var people: [PersonHit] = []
    @State private var page = 1
    @State private var totalPages = 1
    @State private var loading = false

    private let peopleColumns = [GridItem(.adaptive(minimum: 110, maximum: 140),
                                          spacing: 18, alignment: .top)]

    var body: some View {
        Group {
            if ref.category == .people {
                ScrollView {
                    LazyVGrid(columns: peopleColumns, alignment: .leading, spacing: 22) {
                        ForEach(people) { person in
                            PersonCell(person: person)
                                .onAppear {
                                    if person.id == people.last?.id { loadMore() }
                                }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    if loading && !people.isEmpty {
                        ProgressView().padding(.vertical, 16)
                    }
                }
            } else {
                MediaCollectionView(.search(ref.category), items: items,
                                    loading: loading, onReachEnd: { loadMore() })
                    .safeAreaInset(edge: .top) {
                        HStack(spacing: 10) {
                            Spacer()
                            QuizThisControl(.search(ref.category), items: items,
                                            name: ref.query)
                            CollectionSortMenu(.search(ref.category))
                            MediaLayoutPicker(.search(ref.category))
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, pageChromeTop)
                        .padding(.bottom, 6)
                    }
            }
        }
        .overlay {
            if items.isEmpty && people.isEmpty {
                if loading {
                    ProgressView()
                } else {
                    QuietMessage(systemImage: "questionmark.circle",
                                 title: String(localized: "No results", bundle: .module),
                                 subtitle: nil)
                }
            }
        }
        .floatingBackButton()
        .task(id: ref) { await load(reset: true) }
    }

    private func loadMore() {
        guard !loading, page <= totalPages else { return }
        Task { await load(reset: false) }
    }

    private func load(reset: Bool) async {
        if reset {
            page = 1
            totalPages = 1
        }
        loading = true
        defer { loading = false }
        let tmdb = TMDBService(apiKey: config.tmdbApiKey, region: config.watchRegion)
        guard let result = try? await tmdb.searchPage(ref.category, query: ref.query, page: page)
        else { return }
        totalPages = result.totalPages
        if reset {
            items = result.items
            people = result.people
        } else {
            let knownItems = Set(items.map(\.id))
            items += result.items.filter { !knownItems.contains($0.id) }
            let knownPeople = Set(people.map(\.id))
            people += result.people.filter { !knownPeople.contains($0.id) }
        }
        page += 1
    }
}

/// Round portrait + name, navigating to the person page.
struct PersonCell: View {
    let person: PersonHit

    var body: some View {
        NavigationLink(value: PersonRef(id: person.id, name: person.name)) {
            VStack(spacing: 6) {
                RemoteImage(url: person.photoURL)
                    .frame(width: 92, height: 92)
                    .clipShape(Circle())
                Text(person.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 104)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}
