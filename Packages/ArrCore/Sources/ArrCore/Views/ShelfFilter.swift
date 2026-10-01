import SwiftUI

/// What the Shelf shows: which library, in what order, and the narrowing on top of it.
struct ShelfFilter: Equatable {
    var source: QueueItem.Source
    var sort: SortMode = .dateAdded
    var descending = true
    /// Non-nil means shuffled; a new seed reshuffles.
    var shuffleSeed: Int? = .random(in: 1...Int(Int32.max))
    var genre: String?
    var decade: Int?
    var unwatchedOnly = false
    /// TMDB lists only: titles the arr already has.
    var inLibraryOnly = false

    var isNarrowed: Bool { genre != nil || decade != nil || unwatchedOnly || inLibraryOnly }
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
    var key: String { "\(sortKey)|\(genre ?? "")|\(decade.map(String.init) ?? "")|\(unwatchedOnly)|\(inLibraryOnly)" }

    func matches(_ entry: LibraryEntry) -> Bool {
        if let genre, !entry.genres.contains(genre) { return false }
        if let decade, (entry.year ?? 0) / 10 * 10 != decade { return false }
        if unwatchedOnly, entry.watched { return false }
        if inLibraryOnly, entry.arrId == 0 { return false }
        return true
    }

    mutating func clearNarrowing() {
        genre = nil
        decade = nil
        unwatchedOnly = false
        inLibraryOnly = false
    }
}

/// One glass button in the Shelf's corner; the menu holds every choice, and a short summary appears beside the
/// glyph only while something is narrowed.
struct ShelfFilterMenu: View {
    @Binding var filter: ShelfFilter
    let sources: [QueueItem.Source]
    /// The whole library of the current source, for the genre and decade lists.
    let library: [LibraryEntry]
    let sortModes: [SortMode]
    let watchStateKnown: Bool
    var showsLibraryToggle = false
    @Environment(\.locale) private var locale

    var body: some View {
        ShelfCornerButton(
            symbol: filter.isNarrowed ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
            title: Text(verbatim: summary),
            titleLeading: true
        ) {
            content
        }
    }

    /// What's narrowed, or the menu's name when nothing is.
    private var summary: String {
        var parts: [String] = []
        if sources.count > 1 { parts.append(filter.source.displayName) }
        if let genre = filter.genre { parts.append(GenreName.localized(genre, locale: locale)) }
        if let decade = filter.decade { parts.append("\(decade)–\(decade + 9)") }
        if filter.unwatchedOnly { parts.append(AppLocalized.string("shelf.filter.unwatched", locale: locale)) }
        if filter.inLibraryOnly { parts.append(AppLocalized.string("shelf.filter.inLibrary", locale: locale)) }
        return parts.isEmpty ? AppLocalized.string("common.filter.button", locale: locale) : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if sources.count > 1 {
            // A `Picker`, like the Library tab: AppKit owns the checkmark.
            // Clears the narrowing in the same change: a genre from the other library would empty the new one.
            Picker(selection: Binding(get: { filter.source }, set: { filter.source = $0; filter.clearNarrowing() })) {
                ForEach(sources, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        }
        Picker(selection: $filter.genre) {
            Text("shelf.filter.anyGenre", bundle: .module).tag(String?.none)
            ForEach(genres, id: \.self) { genre in
                Text(verbatim: GenreName.localized(genre, locale: locale)).tag(String?.some(genre))
            }
        } label: {
            Text("shelf.filter.genre", bundle: .module)
        }
        .pickerStyle(.menu)
        Picker(selection: $filter.decade) {
            Text("shelf.filter.anyYear", bundle: .module).tag(Int?.none)
            ForEach(decades, id: \.self) { decade in
                Text(verbatim: "\(decade)–\(decade + 9)").tag(Int?.some(decade))
            }
        } label: {
            Text("shelf.filter.years", bundle: .module)
        }
        .pickerStyle(.menu)
        Menu {
            ForEach(sortModes, id: \.self) { mode in
                let selected = filter.shuffleSeed == nil && filter.sort == mode
                Button {
                    if selected { filter.descending.toggle() } else { filter.sort = mode }
                    filter.shuffleSeed = nil
                } label: {
                    Label {
                        mode.label
                    } icon: {
                        Image(systemName: selected ? (filter.descending ? "arrow.down" : "arrow.up") : mode.symbolName)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            Button {
                filter.shuffleSeed = Int.random(in: 1...Int(Int32.max))
            } label: {
                Label {
                    Text("shelf.sort.random", bundle: .module)
                } icon: {
                    Image(systemName: filter.shuffleSeed == nil ? "shuffle" : "checkmark")
                }
                .labelStyle(.titleAndIcon)
            }
        } label: {
            Text("shelf.filter.sort", bundle: .module)
        }
        if watchStateKnown {
            Toggle(isOn: $filter.unwatchedOnly) {
                Text("shelf.filter.unwatched", bundle: .module)
            }
        }
        if showsLibraryToggle {
            Toggle(isOn: $filter.inLibraryOnly) {
                Text("shelf.filter.inLibrary", bundle: .module)
            }
        }
        if filter.isNarrowed {
            Divider()
            Button { filter.clearNarrowing() } label: {
                Text("queue.clearFilter.button", bundle: .module)
            }
        }
    }

    /// Most common first; a long tail of one-off genres would bury the useful ones.
    private var genres: [String] {
        var counts: [String: Int] = [:]
        for entry in library { for genre in entry.genres { counts[genre, default: 0] += 1 } }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(20).map(\.key)
    }

    private var decades: [Int] {
        Set(library.compactMap { $0.year.map { $0 / 10 * 10 } }).filter { $0 > 1800 }.sorted(by: >)
    }
}
