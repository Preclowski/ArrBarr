import os
import SwiftUI
import MediaKit

#if os(iOS)
/// `isSearching` is only readable from inside the searchable content, hence the wrapper.
private struct LibraryFilterStrip<Content: View>: View {
    @Environment(\.isSearching) private var isSearching
    @ViewBuilder var content: () -> Content

    var body: some View {
        if !isSearching { content() }
    }
}
#else
private struct LibraryFilterStrip<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
#endif

// MARK: - Browsing state

enum ViewMode: String { case grid, list }

enum StatusFilter: CaseIterable {
    case all, missing, unmonitored

    var cacheKey: String { String(describing: self) }

    var labelKey: String {
        switch self {
        case .all: return "search.all.button"
        case .missing: return "search.missing.button"
        case .unmonitored: return "Unmonitored"
        }
    }
}

enum SortMode: CaseIterable {
    case title, releaseDate, dateAdded, size, imdb, tmdb, rating

    /// Must stay 1:1 with `areInIncreasingOrder`; "title" is also the view model's pre-warm key.
    var cacheKey: String { String(describing: self) }

    /// Every axis is ascending; the view's direction flag decides how it is read,
    /// so the direction survives a change of axis.
    var areInIncreasingOrder: (LibraryEntry, LibraryEntry) -> Bool {
        switch self {
        case .title:
            return LibraryViewModel.titleAscending
        case .releaseDate:
            // Undated entries sort as oldest so they gather at one end.
            return { ($0.releaseSortKey, $0.title) < ($1.releaseSortKey, $1.title) }
        case .dateAdded:
            return { ($0.dateAdded ?? .distantPast, $0.title) < ($1.dateAdded ?? .distantPast, $1.title) }
        case .size:
            return { $0.sizeOnDisk < $1.sizeOnDisk }
        case .imdb:
            return { ($0.ratingImdb ?? -1) < ($1.ratingImdb ?? -1) }
        case .tmdb:
            return { ($0.ratingTmdb ?? -1) < ($1.ratingTmdb ?? -1) }
        case .rating:
            return { ($0.ratingArr ?? -1) < ($1.ratingArr ?? -1) }
        }
    }

    var label: Text {
        switch self {
        case .title: return Text("library.sort.title", bundle: .module)
        case .releaseDate: return Text("library.sort.releaseDate", bundle: .module)
        case .dateAdded: return Text("library.sort.dateAdded", bundle: .module)
        case .size: return Text("queue.size.button", bundle: .module)
        case .imdb: return Text(verbatim: "IMDb")
        case .tmdb: return Text(verbatim: "TMDB")
        case .rating: return Text("Rating", bundle: .module)
        }
    }

    /// Plain `Image(systemName:)` only: a menu row drops any other image view.
    /// `.rating` is the single score the source ships (TVDB for Sonarr), so a plain star.
    var symbolName: String {
        switch self {
        case .title: return "textformat"
        case .releaseDate: return "calendar"
        case .dateAdded: return "tray.and.arrow.down"
        case .size: return "internaldrive"
        case .imdb: return "star.square"
        case .tmdb: return "star.circle"
        case .rating: return "star"
        }
    }

    /// Radarr sorts IMDb and TMDB separately; Sonarr and Lidarr ship one score, Whisparr none.
    /// Lidarr has no release date (albums do, artists don't).
    static func available(for source: QueueItem.Source) -> [SortMode] {
        switch source {
        case .radarr: return [.title, .releaseDate, .dateAdded, .size, .imdb, .tmdb]
        case .sonarr: return [.title, .releaseDate, .dateAdded, .size, .rating]
        case .whisparr: return [.title, .releaseDate, .dateAdded, .size]
        case .lidarr: return [.title, .dateAdded, .size, .rating]
        }
    }
}

/// The browsing strip and cover grid; search is wrapped above the tabs by `SearchHost`.
struct LibraryTabContent: View {
    var viewModel: LibraryViewModel
    @EnvironmentObject var configStore: ConfigStore

    @State private var source: QueueItem.Source = .radarr
    @State private var sourceResolved = false
    @State private var statusFilter: StatusFilter = .all
    @State private var sort: SortMode = .title
    /// Not reset on axis change: only picking the selected axis again flips it.
    @State private var sortDescending = false
    @AppStorage("libraryViewMode") private var viewModeRaw = ViewMode.grid.rawValue

    private var viewMode: ViewMode {
        ViewMode(rawValue: viewModeRaw) ?? .grid
    }

    private var availableSources: [QueueItem.Source] {
        QueueItem.Source.allCases.filter { configStore.config(for: $0.serviceKind).isVisible }
    }

    private var allEntries: [LibraryEntry] {
        viewModel.entries[source] ?? []
    }

    private func matches(_ entry: LibraryEntry, filter: StatusFilter) -> Bool {
        switch filter {
        case .all: return true
        // Includes not-yet-available titles; their chip explains why.
        case .missing: return entry.state == .missing || entry.state == .partial || entry.state == .notAvailable
        case .unmonitored: return entry.state == .unmonitored
        }
    }

    private var filterCounts: [StatusFilter: Int] {
        var out: [StatusFilter: Int] = [:]
        for filter in StatusFilter.allCases {
            out[filter] = viewModel.count(source, cacheKey: filter.cacheKey, over: allEntries) {
                matches($0, filter: filter)
            }
        }
        return out
    }

    private var visibleEntries: [LibraryEntry] {
        // Sort first through the memoized cache (the localized title sort costs ~20ms at ~3k entries);
        // filtering keeps order. Title-ascending must equal `LibraryViewModel.defaultSortCacheKey`, the pre-warmed order.
        let axisKey = "\(sort.cacheKey)|\(sortDescending ? "desc" : "asc")"
        let ascending = sort.areInIncreasingOrder
        let comparator: (LibraryEntry, LibraryEntry) -> Bool = sortDescending
            ? { ascending($1, $0) }
            : ascending
        let sorted = viewModel.sorted(source, cacheKey: axisKey, using: comparator)
        // Memoized: re-filtering ~3k records copies the array on every `surface` pass.
        return viewModel.visible(source, cacheKey: "\(axisKey)|\(statusFilter.cacheKey)",
                                 from: sorted) { matches($0, filter: statusFilter) }
    }

    var body: some View {
        surface
        .onAppear {
            // Once only: re-running on every appear would fight a manual pick.
            if !sourceResolved {
                sourceResolved = true
                if let first = availableSources.first, !availableSources.contains(source) {
                    source = first
                }
            }
            Task { await load() }
        }
        .onChange(of: source) { _, _ in
            // An axis the new arr doesn't offer (IMDb on Sonarr) resets rather than sorting on nils.
            if !SortMode.available(for: source).contains(sort) { sort = .title }
            Task { await load() }
        }
    }

    private func load(force: Bool = false) async {
        await viewModel.loadIfNeeded(
            source: source,
            config: configStore.config(for: source.serviceKind),
            force: force
        )
    }

    // MARK: - Grid

    @ViewBuilder
    private func gridOrState(_ entries: [LibraryEntry], phase: Phase) -> some View {
        switch phase {
        case .loading:
            ScrollView {
                LoadingStateView()
                    .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
        case .failed:
            emptyState(symbol: "exclamationmark.triangle", textKey: "library.error.title") {
                Button {
                    Task { await load(force: true) }
                } label: {
                    Text("common.retry.button", bundle: .module)
                }
                .modifier(GlassButtonStyle())
            }
        case .empty:
            emptyState(symbol: "books.vertical", textKey: "library.empty.title") { EmptyView() }
        case .content:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewMode == .grid {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(entries) { entry in
                                LibraryTile(entry: entry, apiKey: apiKey(for: entry))
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                LibraryListRow(entry: entry, apiKey: apiKey(for: entry))
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.top, 2)
                    }
                }
                // Keeps the last row clear of the floating capsule.
                .padding(.bottom, 58)
            }
            // The host tears this view down on tab switch, so the position lives on the view model.
            .scrollPosition(id: gridAnchor, anchor: .top)
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .frame(maxHeight: .infinity)
        }
    }

    /// Not `@State`: the scroll view writes this every drag frame, and the model stores it
    /// `@ObservationIgnored` so those writes invalidate nothing.
    private var gridAnchor: Binding<LibraryEntry.ID?> {
        Binding(get: { viewModel.gridAnchor[source] },
                set: { viewModel.gridAnchor[source] = $0 })
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 10, alignment: .top)]
    }

    private func apiKey(for entry: LibraryEntry) -> String? {
        entry.posterRequiresAuth ? configStore.config(for: entry.source.serviceKind).apiKey : nil
    }

    private func emptyState(symbol: String, textKey: String, @ViewBuilder accessory: () -> some View) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .scaledFont(size: 24, weight: .light)
                    .foregroundStyle(.tertiary)
                Text(LocalizedStringKey(textKey), bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                accessory()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Surface

    private enum Phase: Equatable { case loading, failed, empty, content }

    private func phase(_ entries: [LibraryEntry]) -> Phase {
        if allEntries.isEmpty {
            if viewModel.loadFailed.contains(source) { return .failed }
            // A never-projected source counts as loading, or the "empty library" state flashes first.
            if viewModel.entries[source] == nil || viewModel.loading.contains(source) { return .loading }
        }
        return entries.isEmpty ? .empty : .content
    }

    /// No transition between states: an `.id(phase)` cross-fade re-identified the grid and
    /// re-animated covers that were already cached.
    private var surface: some View {
        let entries = visibleEntries
        let phase = phase(entries)
        return gridOrState(entries, phase: phase)
            .safeAreaBar(edge: .top, spacing: 0) {
                LibraryFilterStrip {
                    LibraryFilterBar(sources: availableSources,
                                     counts: filterCounts,
                                     source: $source,
                                     statusFilter: $statusFilter,
                                     sort: $sort,
                                     sortDescending: $sortDescending,
                                     viewModeRaw: $viewModeRaw)
                }
            }
    }
}
