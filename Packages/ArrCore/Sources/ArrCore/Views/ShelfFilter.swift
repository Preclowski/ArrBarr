import SwiftUI

/// What the Shelf shows: which library, in what order, and the narrowing on top of it.
struct ShelfFilter: Equatable {
    var source: QueueItem.Source
    var sort: SortMode = .dateAdded
    var descending = true
    /// Non-nil means shuffled; a new seed reshuffles.
    var shuffleSeed: Int? = .random(in: 1...Int(Int32.max))
    /// Any of these; empty is every genre.
    var genres: Set<String> = []
    var decade: Int?
    var unwatchedOnly = false
    /// TMDB lists only: titles the arr already has.
    var inLibraryOnly = false

    var isNarrowed: Bool { !genres.isEmpty || decade != nil || unwatchedOnly || inLibraryOnly }
    var sortKey: String { shuffleSeed.map { "shelf|random|\($0)" } ?? "shelf|\(sort.cacheKey)|\(descending)" }

    func areInIncreasingOrder(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        if let shuffleSeed {
            // Seeded, so the order holds while scrolling and changes only on a reshuffle.
            return Self.mix(a.id, shuffleSeed) < Self.mix(b.id, shuffleSeed)
        }
        return descending ? sort.areInIncreasingOrder(b, a) : sort.areInIncreasingOrder(a, b)
    }

    private static func mix(_ id: String, _ seed: Int) -> UInt64 {
        var h: UInt64 = 14695981039346656037 &+ UInt64(bitPattern: Int64(seed))
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return h
    }
    var key: String { "\(sortKey)|\(genres.sorted().joined(separator: ","))|\(decade.map(String.init) ?? "")|\(unwatchedOnly)|\(inLibraryOnly)" }

    enum Facet { case genre, decade }

    func matches(_ entry: LibraryEntry) -> Bool { matches(entry, ignoring: nil) }

    /// Leaving one facet out gives that facet's own counts: what picking another value of it would show.
    func matches(_ entry: LibraryEntry, ignoring facet: Facet?) -> Bool {
        if facet != .genre, !genres.isEmpty, genres.isDisjoint(with: entry.genres) { return false }
        if facet != .decade, let decade, (entry.year ?? 0) / 10 * 10 != decade { return false }
        if unwatchedOnly, entry.watched { return false }
        if inLibraryOnly, entry.arrId == 0 { return false }
        return true
    }

    mutating func clearNarrowing() {
        genres = []
        decade = nil
        unwatchedOnly = false
        inLibraryOnly = false
    }
}

/// Every narrowing at once: source, order, genres and decades, the counts already narrowed by the rest.
struct ShelfFilterPanel: View {
    @Binding var filter: ShelfFilter
    let sources: [QueueItem.Source]
    /// The whole set of the current source, for the genre and decade lists.
    let library: [LibraryEntry]
    let sortModes: [SortMode]
    let watchStateKnown: Bool
    var showsLibraryToggle = false
    @State private var hoveredSort: SortChoice?
    @State private var hoveredDecade: Int?

    enum SortChoice: Hashable {
        case random
        case mode(SortMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sources.count > 1 {
                ShelfSegments(items: sources, selected: filter.source, height: 22, action: { source in
                    // A genre from the other library would empty the new one.
                    filter.source = source
                    filter.clearNarrowing()
                }) { source, _ in
                    Text(verbatim: source.displayName).scaledFont(size: 11.5, weight: .semibold)
                }
                .frame(width: 140)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            ShelfPanelSection(title: "shelf.filter.sort") { sortHint } content: {
                ShelfSegments(items: [.random] + sortModes.map(SortChoice.mode), selected: selectedSort, height: 28,
                              action: pick, onHover: { hoveredSort = $0 }) { choice, on in
                    sortIcon(choice, on: on)
                }
            }
            ShelfPanelSection(title: "shelf.filter.genre") {
                GenreChipCloud(genres: $filter.genres, all: library) { filter.matches($0, ignoring: .genre) }
            }
            if !DecadeHistogram.decades(in: library).isEmpty {
                ShelfPanelSection(title: "shelf.filter.years") {
                    DecadeHint(decade: hoveredDecade ?? filter.decade)
                } content: {
                    DecadeHistogram(decade: $filter.decade, hovered: $hoveredDecade, all: library) {
                        filter.matches($0, ignoring: .decade)
                    }
                }
            }
            HStack {
                if watchStateKnown {
                    Toggle(isOn: $filter.unwatchedOnly) { Text("shelf.filter.unwatched", bundle: .module) }
                } else if showsLibraryToggle {
                    Toggle(isOn: $filter.inLibraryOnly) { Text("shelf.filter.inLibrary", bundle: .module) }
                }
                Spacer(minLength: 8)
                Button { filter.clearNarrowing() } label: {
                    Label { Text("queue.clearFilter.button", bundle: .module) } icon: { Image(systemName: "xmark") }
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(filter.isNarrowed ? 1 : 0)
                .allowsHitTesting(filter.isNarrowed)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .scaledFont(size: 12, weight: .medium)
            .padding(.horizontal, 2)
        }
        .frame(width: 352)
        .animation(.easeOut(duration: 0.15), value: filter)
    }

    // MARK: - Sort

    private var selectedSort: SortChoice { filter.shuffleSeed == nil ? .mode(filter.sort) : .random }

    private func pick(_ choice: SortChoice) {
        switch choice {
        case .random:
            filter.shuffleSeed = Int.random(in: 1...Int(Int32.max))
        case .mode(let mode):
            if selectedSort == choice { filter.descending.toggle() } else { filter.sort = mode }
            filter.shuffleSeed = nil
        }
    }

    private func sortIcon(_ choice: SortChoice, on: Bool) -> some View {
        HStack(spacing: 2) {
            switch choice {
            case .random:
                Image(systemName: "shuffle")
            case .mode(let mode):
                Image(systemName: mode.symbolName)
                if on { Image(systemName: filter.descending ? "arrow.down" : "arrow.up").scaledFont(size: 9, weight: .bold) }
            }
        }
        .scaledFont(size: 12, weight: .semibold)
    }

    @ViewBuilder
    private var sortHint: some View {
        switch hoveredSort ?? selectedSort {
        case .random:
            Text("shelf.sort.random", bundle: .module)
        case .mode(let mode):
            HStack(spacing: 3) {
                mode.label
                if hoveredSort == nil { Image(systemName: filter.descending ? "arrow.down" : "arrow.up").scaledFont(size: 9, weight: .bold) }
            }
        }
    }
}
