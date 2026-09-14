import SwiftUI
import SwiftData

// MARK: - Layout

/// The two ways a collection of titles can be shown. Every library view that
/// used to be a bare poster grid goes through `MediaCollectionView`, so the
/// switch — and the column set behind the list — works the same everywhere.
public enum MediaLayout: String, CaseIterable, Identifiable, Sendable {
    case posters
    case list

    public var id: String { rawValue }
    var symbol: String { self == .posters ? "square.grid.2x2" : "list.bullet" }
    var title: String {
        self == .posters
            ? String(localized: "as Posters", bundle: .module)
            : String(localized: "as List", bundle: .module)
    }
}

/// How a card is cut in the poster grid: the tall 2:3 poster, or the wide
/// 16:9 backdrop. `PosterCard` has drawn both from the start; until now only
/// the shelves used the wide cut.
public enum PosterStyle: String, CaseIterable, Identifiable, Sendable {
    case classic
    case wide

    public var id: String { rawValue }
    var title: String {
        self == .classic
            ? String(localized: "Classic", bundle: .module)
            : String(localized: "Widescreen", bundle: .module)
    }
    var symbol: String { self == .classic ? "rectangle.portrait" : "rectangle" }
}

/// Grid density. Three steps rather than a slider: a menu hosts a picker
/// natively and a slider awkwardly, and how big a poster should be is a
/// coarse preference, not a continuous one.
public enum CardSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    public var id: String { rawValue }
    var title: String {
        switch self {
        case .small: return String(localized: "Small", bundle: .module)
        case .medium: return String(localized: "Medium", bundle: .module)
        case .large: return String(localized: "Large", bundle: .module)
        }
    }
    /// Symbol-only in the menu — three words of Polish would not fit a
    /// palette row, three grids of decreasing density need no words at all.
    var symbol: String {
        switch self {
        case .small: return "square.grid.4x3.fill"
        case .medium: return "square.grid.3x3.fill"
        case .large: return "square.grid.2x2.fill"
        }
    }

    /// Card width for a style. The wide cut carries a 16:9 still, which needs
    /// roughly twice the width of a poster to read at all.
    func width(_ style: PosterStyle) -> CGFloat {
        switch (style, self) {
        case (.classic, .small): return 130
        case (.classic, .medium): return 155
        case (.classic, .large): return 190
        case (.wide, .small): return 230
        case (.wide, .medium): return 280
        case (.wide, .large): return 330
        }
    }
}

// MARK: - Sort

/// The one sort model in the app: what the header's Sort menu offers, what a
/// table's column headers write into, and what a client-side collection is
/// ordered by.
///
/// It exists because sorting used to live in three places that could disagree
/// — an inert label in the page header, a chip row inside the filter panel,
/// and the table's own private `sortOrder`. In the list layout the header
/// could say "Popularity" while the table was sorted by title.
public enum CollectionSort: String, CaseIterable, Identifiable, Sendable {
    /// The order the collection arrived in: TMDB's popularity for a browse
    /// page, "recently added" for a list, the log's own order for the Quiz
    /// history. Never a client-side re-sort.
    case popularity
    case rating
    case newest
    case votes
    case title

    public var id: String { rawValue }

    /// `popularity` is TMDB's word for it; in a collection the app already
    /// holds there is no popularity to sort by — it means "the order this
    /// collection keeps for itself".
    func displayName(server: Bool) -> String {
        switch self {
        case .popularity:
            return server
                ? String(localized: "Popularity", bundle: .module)
                : String(localized: "Default Order", bundle: .module)
        case .rating: return String(localized: "Rating", bundle: .module)
        case .newest: return String(localized: "Newest", bundle: .module)
        case .votes: return String(localized: "Most Voted", bundle: .module)
        case .title: return String(localized: "Title", bundle: .module)
        }
    }

    var symbol: String {
        switch self {
        case .popularity: return "flame"
        case .rating: return "star"
        case .newest: return "calendar"
        case .votes: return "person.3"
        case .title: return "textformat"
        }
    }

    /// The `/discover` sort this maps to, or nil when TMDB cannot express it.
    /// A sort with no answer here is never offered on a server-sorted page.
    var discover: DiscoverFilter.Sort? {
        switch self {
        case .popularity: return .popularity
        case .rating: return .rating
        case .newest: return .newest
        case .votes: return .votes
        case .title: return nil
        }
    }

    init(_ sort: DiscoverFilter.Sort) {
        switch sort {
        case .popularity: self = .popularity
        case .rating: self = .rating
        case .newest: self = .newest
        case .votes: self = .votes
        }
    }

    /// How the table sorts by this key, and how a client-side collection is
    /// ordered. Highest / newest first, because nobody browses films from the
    /// worst up; title alone reads A→Z.
    var comparators: [KeyPathComparator<MediaItem>] {
        switch self {
        case .popularity: return []
        case .rating: return [KeyPathComparator(\MediaItem.sortRating, order: .reverse)]
        case .newest: return [KeyPathComparator(\MediaItem.sortYear, order: .reverse)]
        case .votes: return [KeyPathComparator(\MediaItem.sortVotes, order: .reverse)]
        case .title: return [KeyPathComparator(\MediaItem.title)]
        }
    }

    /// The sort a table column header stands for — the header click writes
    /// this back, so clicking "Year" and picking "Newest" are one thing.
    static func forKeyPath(_ path: PartialKeyPath<MediaItem>) -> CollectionSort? {
        switch path {
        case \MediaItem.sortRating: return .rating
        case \MediaItem.sortYear: return .newest
        case \MediaItem.sortVotes: return .votes
        case \MediaItem.title: return .title
        default: return nil
        }
    }
}

// MARK: - Columns

/// The columns the list layout can show. Order here is the default column
/// order; the user reorders, resizes and hides them from the table header
/// (or the View menu's Columns submenu) and the choice is remembered per
/// collection.
enum MediaColumn: String, CaseIterable, Identifiable {
    case title
    case year
    case type
    case rating
    case genres
    case watched
    case verdict
    case overview

    var id: String { rawValue }

    /// The title carries the poster thumbnail — it never hides.
    var fixed: Bool { self == .title }

    var title: String {
        switch self {
        case .title: return String(localized: "Title", bundle: .module)
        case .year: return String(localized: "Year", bundle: .module)
        case .type: return String(localized: "Type", bundle: .module)
        case .rating: return String(localized: "Rating", bundle: .module)
        case .genres: return String(localized: "Genres", bundle: .module)
        case .watched: return String(localized: "Watched", bundle: .module)
        case .verdict: return String(localized: "Decision", bundle: .module)
        case .overview: return String(localized: "Overview", bundle: .module)
        }
    }
}

/// Sort keys — `KeyPathComparator` needs non-optional Comparable values, and
/// the table's cells want ready-made strings.
extension MediaItem {
    var sortYear: Int { year ?? 0 }
    var sortRating: Double { rating ?? -1 }
    var sortVotes: Int { voteCount ?? 0 }
    var typeName: String { type.displayName }
    var sortOverview: String { overview ?? "" }
    var genreNames: String {
        genreIds.compactMap { id -> String? in
            let name = Genres.displayName(for: id, type: type)
            return name.isEmpty ? nil : name
        }.joined(separator: ", ")
    }
}

// MARK: - Collections

/// What a page is showing, and how. Each library page names its collection
/// here instead of passing a bare id string around: the spec carries the
/// storage key, whether the titles come from disk or from TMDB, and which
/// columns are pointless for that page.
struct MediaCollectionSpec: Hashable {
    let id: String
    /// Local (SwiftData) collections hold everything already — they never
    /// page, and never show a "Load More". Only TMDB-backed pages do.
    let isLocal: Bool
    /// The sort is part of the query TMDB answers, not something the page
    /// does to the rows it already has. True only for the browse grids;
    /// everywhere else the collection is sorted where it is drawn.
    let sortsOnServer: Bool
    /// Columns hidden until the user asks for them. A page pinned to one
    /// media type hides Type: it only ever repeats the page's own name.
    let hiddenColumns: Set<MediaColumn>

    private static let optional: Set<MediaColumn> = [.genres, .overview, .watched]

    static func browse(_ type: MediaType) -> MediaCollectionSpec {
        MediaCollectionSpec(id: "browse-\(type.rawValue)", isLocal: false,
                            sortsOnServer: true,
                            hiddenColumns: optional.union([.type]))
    }

    /// All user lists share one layout — switching to the list layout in one
    /// of them is a preference, not a per-list quirk.
    static let lists = MediaCollectionSpec(id: "lists", isLocal: true,
                                           sortsOnServer: false,
                                           hiddenColumns: optional)
    static let watched = MediaCollectionSpec(id: "watched", isLocal: true,
                                             sortsOnServer: false,
                                             hiddenColumns: optional)
    static let quizHistory = MediaCollectionSpec(id: "quiz-history", isLocal: true,
                                                 sortsOnServer: false,
                                                 hiddenColumns: optional)
    static let tmdbList = MediaCollectionSpec(id: "tmdb-list", isLocal: false,
                                              sortsOnServer: false,
                                              hiddenColumns: optional)
    /// One award's winners. Movies only, and the whole catalog arrives at
    /// once — it is a fixed list the app carries, not a TMDB query.
    static let awarded = MediaCollectionSpec(id: "awarded", isLocal: true,
                                             sortsOnServer: false,
                                             hiddenColumns: optional.union([.type]))

    /// A person's filmography, one media type per page. It arrives whole in
    /// the person payload, so it never pages.
    static func personCredits(_ type: MediaType) -> MediaCollectionSpec {
        MediaCollectionSpec(id: "person-credits-\(type.rawValue)", isLocal: true,
                            sortsOnServer: false,
                            hiddenColumns: optional.union([.type]))
    }

    static func search(_ category: TMDBService.SearchCategory) -> MediaCollectionSpec {
        MediaCollectionSpec(id: "search-\(category)", isLocal: false,
                            sortsOnServer: false,
                            hiddenColumns: optional.union([.type]))
    }

    /// What the Sort menu may offer. A server-sorted page can only offer what
    /// `/discover` can answer — sorting a page of 20 out of 10,000 results by
    /// title would order the window, not the result set.
    var sorts: [CollectionSort] {
        sortsOnServer ? CollectionSort.allCases.filter { $0.discover != nil } : CollectionSort.allCases
    }
}

// MARK: - Per-collection options

/// Everything about *how* one collection is displayed — layout, poster cut,
/// density, columns and sort — remembered across launches under the
/// collection's id ("watched", "lists", "browse-movie"…).
///
/// One rule, so nothing has to be looked up twice: the View menu is this
/// object, and this object is what persists. Views get the same instance for
/// the same id, so a picker placed in a page header drives a grid placed
/// anywhere else on that page.
@MainActor
final class MediaCollectionOptions: ObservableObject {
    let spec: MediaCollectionSpec

    var storageID: String { spec.id }

    @Published var layout: MediaLayout {
        didSet { defaults.set(layout.rawValue, forKey: key("layout")) }
    }

    @Published var posterStyle: PosterStyle {
        didSet { defaults.set(posterStyle.rawValue, forKey: key("posterStyle")) }
    }

    @Published var cardSize: CardSize {
        didSet { defaults.set(cardSize.rawValue, forKey: key("cardSize")) }
    }

    /// A standing preference, unlike the filters: a forgotten sort is
    /// harmless, a forgotten filter is a page that looks broken.
    @Published var sort: CollectionSort {
        didSet { defaults.set(sort.rawValue, forKey: key("sort")) }
    }

    @Published var customization: TableColumnCustomization<MediaItem> {
        didSet { persistColumns() }
    }

    private var defaults: UserDefaults { .standard }
    private func key(_ name: String) -> String { "media.\(storageID).\(name)" }

    private init(spec: MediaCollectionSpec) {
        self.spec = spec
        let defaults = UserDefaults.standard
        let id = spec.id
        layout = defaults.string(forKey: "media.\(id).layout")
            .flatMap(MediaLayout.init(rawValue:)) ?? .posters
        posterStyle = defaults.string(forKey: "media.\(id).posterStyle")
            .flatMap(PosterStyle.init(rawValue:)) ?? .classic
        cardSize = defaults.string(forKey: "media.\(id).cardSize")
            .flatMap(CardSize.init(rawValue:)) ?? .medium
        let storedSort = defaults.string(forKey: "media.\(id).sort")
            .flatMap(CollectionSort.init(rawValue:)) ?? .popularity
        // A sort the page cannot honour (a title sort remembered from before
        // the page became server-sorted) falls back rather than lying.
        sort = spec.sorts.contains(storedSort) ? storedSort : .popularity
        if let data = defaults.data(forKey: "media.\(id).columns"),
           let stored = try? JSONDecoder().decode(TableColumnCustomization<MediaItem>.self, from: data) {
            customization = stored
        } else {
            customization = TableColumnCustomization<MediaItem>()
        }
    }

    private func persistColumns() {
        guard let data = try? JSONEncoder().encode(customization) else { return }
        defaults.set(data, forKey: key("columns"))
    }

    /// Untouched columns follow the collection's defaults; once the user
    /// says otherwise, their choice wins.
    func isVisible(_ column: MediaColumn) -> Bool {
        switch customization[visibility: column.id] {
        case .hidden: return false
        case .visible: return true
        default: return !spec.hiddenColumns.contains(column)
        }
    }

    func defaultVisibility(_ column: MediaColumn) -> Visibility {
        spec.hiddenColumns.contains(column) ? .hidden : .automatic
    }

    func setVisible(_ column: MediaColumn, _ visible: Bool) {
        customization[visibility: column.id] = visible ? .visible : .hidden
    }

    /// The rows in the order the page should draw them. A server-sorted page
    /// is already in order — re-sorting it here would reorder the window
    /// rather than the result set.
    func ordered(_ items: [MediaItem]) -> [MediaItem] {
        guard !spec.sortsOnServer else { return items }
        let comparators = sort.comparators
        return comparators.isEmpty ? items : items.sorted(using: comparators)
    }

    private static var registry: [String: MediaCollectionOptions] = [:]

    static func shared(_ spec: MediaCollectionSpec) -> MediaCollectionOptions {
        if let existing = registry[spec.id] { return existing }
        let fresh = MediaCollectionOptions(spec: spec)
        registry[spec.id] = fresh
        return fresh
    }
}

// MARK: - The controls

/// The View menu: one control holding everything about how this collection is
/// drawn — layout, and then whichever options that layout has.
///
/// It replaces a two-button split control where the list button switched on a
/// click and opened its columns on a press. Nothing hinted at the second
/// behaviour, and its tooltip had to explain the control itself — the reliable
/// sign of an undiscoverable one. A menu has room for the poster cut and the
/// density too, without growing the row of chrome by a single button.
struct MediaLayoutPicker: View {
    @ObservedObject var options: MediaCollectionOptions

    init(_ spec: MediaCollectionSpec) { options = MediaCollectionOptions.shared(spec) }
    init(options: MediaCollectionOptions) { self.options = options }

    var body: some View {
        Menu {
            Picker(selection: $options.layout) {
                ForEach(MediaLayout.allCases) { layout in
                    Label(layout.title, systemImage: layout.symbol).tag(layout)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)

            // Only the current layout's options are shown. A card size while
            // the table is up, or a column list while the posters are, is a
            // control that does nothing to what is on screen.
            switch options.layout {
            case .posters:
                Section {
                    Picker(selection: $options.posterStyle) {
                        ForEach(PosterStyle.allCases) { style in
                            Label(style.title, systemImage: style.symbol).tag(style)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.inline)

                    Picker(selection: $options.cardSize) {
                        ForEach(CardSize.allCases) { size in
                            Label(size.title, systemImage: size.symbol).tag(size)
                        }
                    } label: {
                        Text("Card Size", bundle: .module)
                    }
                    .pickerStyle(.palette)
                } header: {
                    Text("Posters", bundle: .module)
                }
            case .list:
                Section {
                    Menu {
                        ForEach(MediaColumn.allCases.filter { !$0.fixed }) { column in
                            Toggle(column.title, isOn: Binding(
                                get: { options.isVisible(column) },
                                set: { options.setVisible(column, $0) }))
                        }
                    } label: {
                        Text("Columns", bundle: .module)
                    }
                } header: {
                    Text("List", bundle: .module)
                }
            }
        } label: {
            Image(systemName: options.layout.symbol)
                .glassControl(active: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("View Options", bundle: .module))
    }
}

/// "Open in Quiz": deal this page's titles into the swipe deck.
///
/// The Quiz's own feed is random by design; this is the other way to fill it
/// — a list, a genre, a person's films, the results you are looking at right
/// now. It hands over `options.ordered(items)`, so the deck arrives in the
/// order the page is actually showing (and, on a paged TMDB page, exactly as
/// far as the user has scrolled).
struct QuizThisControl: View {
    @ObservedObject var options: MediaCollectionOptions
    let items: [MediaItem]
    /// What the deck is called once it is in the Quiz — the list's name, the
    /// genre, the person. Shown on the badge over the cards.
    let name: String

    @Environment(\.openInQuiz) private var openInQuiz

    init(_ spec: MediaCollectionSpec, items: [MediaItem], name: String) {
        self.options = MediaCollectionOptions.shared(spec)
        self.items = items
        self.name = name
    }

    init(options: MediaCollectionOptions, items: [MediaItem], name: String) {
        self.options = options
        self.items = items
        self.name = name
    }

    var body: some View {
        Button {
            openInQuiz(options.ordered(items), named: name)
        } label: {
            // A deck of cards, not sparkles: the button hands these titles to
            // the swipe deck, and that is what the deck looks like.
            Image(systemName: "rectangle.stack")
                .glassControl(active: false)
        }
        .buttonStyle(.plain)
        .disabled(items.isEmpty)
        .help(Text("Open in Quiz", bundle: .module))
    }
}

/// The Sort menu: the page's display order, named by its own label.
///
/// It used to be a caption in the header that named the sort without being
/// able to change it, plus a chip row three clicks into the filter panel.
/// Sorting is not a narrowing of the result set — it is how the page is read,
/// so it belongs out here with the View menu and never behind a panel.
struct CollectionSortMenu: View {
    @ObservedObject var options: MediaCollectionOptions

    init(_ spec: MediaCollectionSpec) { options = MediaCollectionOptions.shared(spec) }
    init(options: MediaCollectionOptions) { self.options = options }

    var body: some View {
        Menu {
            Picker(selection: $options.sort) {
                ForEach(options.spec.sorts) { sort in
                    Label(sort.displayName(server: options.spec.sortsOnServer),
                          systemImage: sort.symbol)
                        .tag(sort)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                Text(options.sort.displayName(server: options.spec.sortsOnServer))
            }
            .glassControl(active: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Sort", bundle: .module))
    }
}

// MARK: - The module

/// Universal collection view: the same titles as a poster grid or as a
/// customizable table, scrolling included. Pages own the header and the
/// empty state; this owns the presentation of the items.
struct MediaCollectionView: View {
    @ObservedObject private var options: MediaCollectionOptions
    private let items: [MediaItem]
    /// Multi-select. The table always uses it (native row selection); the
    /// poster grid only while `selectionActive`.
    private let selection: Binding<Set<String>>?
    private let selectionActive: Bool
    private let loading: Bool
    private let onReachEnd: (() -> Void)?
    /// Liked / skipped / not in the log — the Quiz history's own column. Any
    /// other collection leaves it out entirely.
    private let verdict: ((MediaItem) -> Bool?)?

    init(_ spec: MediaCollectionSpec,
         items: [MediaItem],
         selection: Binding<Set<String>>? = nil,
         selectionActive: Bool = false,
         loading: Bool = false,
         verdict: ((MediaItem) -> Bool?)? = nil,
         onReachEnd: (() -> Void)? = nil) {
        self.options = MediaCollectionOptions.shared(spec)
        self.items = items
        self.selection = selection
        self.selectionActive = selectionActive
        self.loading = loading
        self.verdict = verdict
        // Paging is a TMDB thing. A local collection is already whole, so it
        // never asks for more — and never grows a "Load More" footer.
        self.onReachEnd = spec.isLocal ? nil : onReachEnd
    }

    /// One order for both layouts: the posters and the table are the same
    /// collection seen two ways, and they must never be in different orders.
    private var rows: [MediaItem] { options.ordered(items) }

    var body: some View {
        content
            // ⌘1 / ⌘2 refund the click the View menu costs a power user.
            // Hidden rather than in the menu bar: the window's toolbar and
            // menu commands are off limits here (see `WindowChrome`), and a
            // shortcut scoped to the page on screen cannot fire on another.
            .background {
                ZStack {
                    Button("") { options.layout = .posters }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("") { options.layout = .list }
                        .keyboardShortcut("2", modifiers: .command)
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch options.layout {
        case .posters:
            ScrollView {
                PosterGrid(items: rows,
                           style: options.posterStyle,
                           size: options.cardSize,
                           onReachEnd: onReachEnd,
                           selection: selectionActive ? selection : nil)
                if loading && !items.isEmpty {
                    ProgressView().padding(.vertical, 16)
                }
            }
        case .list:
            MediaTable(items: rows, options: options, selection: selection,
                       loading: loading, verdict: verdict, onReachEnd: onReachEnd)
        }
    }
}

// MARK: - Table

private struct MediaTable: View {
    let items: [MediaItem]
    @ObservedObject var options: MediaCollectionOptions
    var selection: Binding<Set<String>>?
    var loading: Bool
    var verdict: ((MediaItem) -> Bool?)?
    var onReachEnd: (() -> Void)?

    @State private var localSelection = Set<String>()
    /// Mirrors `options.sort` both ways: the menu writes here so the header
    /// shows the native sort indicator, and a header click writes back so the
    /// menu, the posters and the table can never name different orders. The
    /// direction stays the table's own business — the menu names the key.
    @State private var sortOrder: [KeyPathComparator<MediaItem>] = []
    @Environment(\.openTitle) private var openTitle

    @ViewBuilder
    private func titleCell(_ item: MediaItem) -> some View {
        HStack(spacing: 10) {
            RemoteImage(url: item.displayPosterURL)
                .frame(width: 30, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(item.title).lineLimit(1)
        }
    }

    @ViewBuilder
    private func typeCell(_ item: MediaItem) -> some View {
        Label {
            Text(item.typeName)
        } icon: {
            Image(systemName: item.type == .movie ? "film" : "tv")
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func genresCell(_ item: MediaItem) -> some View {
        Text(item.genreNames).lineLimit(1).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func overviewCell(_ item: MediaItem) -> some View {
        Text(item.overview ?? "").lineLimit(1).foregroundStyle(.secondary)
    }

    /// The rows are already in the collection's order; the table only
    /// re-sorts when the header asked for something of its own.
    ///
    /// A header the page's sort can name (Year, Rating, Title where the app
    /// holds the whole collection) writes back into that sort, so the menu,
    /// the posters and the table can never say different things. A header it
    /// cannot name — Title on a page TMDB sorts, Genres, Overview — orders
    /// the rows that are loaded, and only those: the native table behaviour,
    /// scoped to what is actually on screen.
    private var rows: [MediaItem] {
        sortOrder.isEmpty ? items : items.sorted(using: sortOrder)
    }

    var body: some View {
        Table(of: MediaItem.self,
              selection: selection ?? $localSelection,
              sortOrder: $sortOrder,
              columnCustomization: $options.customization) {
            // The thumbnail rides in the title cell: as a column of its own
            // it needed a header, and no header fits 34pt.
            TableColumn(MediaColumn.title.title, value: \.title) { titleCell($0) }
                .width(min: 200, ideal: 320)
                .customizationID(MediaColumn.title.id)
                .disabledCustomizationBehavior(.visibility)

            TableColumn(MediaColumn.year.title, value: \.sortYear) { item in
                Text(item.year.map(String.init) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 48, ideal: 56)
            .customizationID(MediaColumn.year.id)
            .defaultVisibility(options.defaultVisibility(.year))

            TableColumn(MediaColumn.type.title, value: \.typeName) { typeCell($0) }
                .width(min: 70, ideal: 100)
                .customizationID(MediaColumn.type.id)
                .defaultVisibility(options.defaultVisibility(.type))

            // Scores go through the one ratings control — service icon,
            // value and that service's vote count — never a bare number.
            TableColumn(MediaColumn.rating.title, value: \.sortRating) { item in
                let scores = ServiceScore.row(tmdb: item.rating, votes: item.voteCount)
                if scores.isEmpty {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    ScoreStrip(scores: scores, style: .chip)
                }
            }
            .width(min: 120, ideal: 150)
            .customizationID(MediaColumn.rating.id)
            .defaultVisibility(options.defaultVisibility(.rating))

            TableColumn(MediaColumn.genres.title, value: \.genreNames) { genresCell($0) }
                .width(min: 100, ideal: 180)
                .customizationID(MediaColumn.genres.id)
                .defaultVisibility(options.defaultVisibility(.genres))

            TableColumn(MediaColumn.watched.title) { item in
                WatchedCell(item: item)
            }
            .width(min: 60, ideal: 70)
            .customizationID(MediaColumn.watched.id)
            .defaultVisibility(options.defaultVisibility(.watched))

            if let verdict {
                TableColumn(MediaColumn.verdict.title) { (item: MediaItem) in
                    switch verdict(item) {
                    case true?:
                        Label { Text("Liked", bundle: .module) } icon: {
                            Image(systemName: "heart.fill").foregroundStyle(.pink)
                        }
                    case false?:
                        Label { Text("Skipped", bundle: .module) } icon: {
                            Image(systemName: "xmark")
                        }
                        .foregroundStyle(.secondary)
                    case nil:
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 90, ideal: 110)
                .customizationID(MediaColumn.verdict.id)
            }

            TableColumn(MediaColumn.overview.title, value: \.sortOverview) { overviewCell($0) }
                .width(min: 120, ideal: 320)
                .customizationID(MediaColumn.overview.id)
                .defaultVisibility(options.defaultVisibility(.overview))
        } rows: {
            ForEach(rows) { item in
                TableRow(item)
            }
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: MediaItem.ID.self) { ids in
            if let item = single(ids) {
                Button { open(item) } label: { Text("Open", bundle: .module) }
                Divider()
                WatchedToggle(item: item)
                AddToListMenu(item: item)
            }
        } primaryAction: { ids in
            if let item = single(ids) { open(item) }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .onAppear { adoptSort() }
        .onChange(of: options.sort) { _, _ in adoptSort() }
        .onChange(of: sortOrder) { _, new in
            // A header click names a key the menu also knows; anything else
            // (a column with no sort of its own) stays the table's business.
            guard let path = new.first?.keyPath,
                  let sort = CollectionSort.forKeyPath(path),
                  options.spec.sorts.contains(sort),
                  sort != options.sort else { return }
            options.sort = sort
        }
    }

    /// Draw the menu's sort in the header, without bouncing it back through
    /// `onChange` as if the user had clicked a column.
    private func adoptSort() {
        let wanted = options.sort.comparators
        guard wanted.first?.keyPath != sortOrder.first?.keyPath else { return }
        sortOrder = wanted
    }

    @ViewBuilder
    private var footer: some View {
        if loading {
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        } else if let onReachEnd, !items.isEmpty {
            Button(action: onReachEnd) { Text("Load More", bundle: .module) }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }

    private func single(_ ids: Set<MediaItem.ID>) -> MediaItem? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return items.first { $0.id == id }
    }

    private func open(_ item: MediaItem) {
        let ordered = rows
        let index = ordered.firstIndex { $0.id == item.id } ?? 0
        openTitle(TitleSelection(items: ordered, index: index))
    }
}

/// Watched state for a table row — SwiftData plus whatever the media server
/// reported, the same rule the poster badge uses.
private struct WatchedCell: View {
    let item: MediaItem
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var externalLibrary: ExternalLibraryStore

    var body: some View {
        let watched = Library.existingTitle(for: item, in: context)?.watchedAt != nil
            || externalLibrary.isWatched(item)
        Image(systemName: watched ? "checkmark.circle.fill" : "circle")
            .symbolRenderingMode(.palette)
            .foregroundStyle(watched ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary),
                             watched ? AnyShapeStyle(.green) : AnyShapeStyle(.clear))
    }
}
