import Foundation

/// What the library list tools were asked for. The three metadata facets
/// (`genre`, `startYear`, `endYear`) are spelled exactly like `tmdb_discover_*`
/// takes them on purpose: it is the same lens, pointed at the user's shelf
/// instead of at TMDB, so the model has one vocabulary rather than two.
///
/// Note what is NOT here: an exclude-genre filter. "Romantic but not a drama"
/// cannot be answered by tags — half the great 90s romances are tagged
/// Drama + Romance — so genres travel in every row and the model applies the
/// judgement. Tools state facts; taste stays with the agent.
public struct LibraryQuery: Sendable, Equatable {
    public var title: String
    public var genre: String
    public var startYear: Int?
    public var endYear: Int?
    public var unwatchedOnly: Bool
    /// Explicit ordering. nil keeps the historical behavior (title-match order,
    /// else rating-desc as a readability default).
    public var sort: LibrarySort?
    /// Row cap requested by the caller. The tool still applies its own hard
    /// cap on top; this exists so "top 10" returns 10 rows, not 100.
    public var limit: Int?

    public init(title: String = "", genre: String = "",
                startYear: Int? = nil, endYear: Int? = nil,
                unwatchedOnly: Bool = false,
                sort: LibrarySort? = nil, limit: Int? = nil) {
        self.title = title
        self.genre = genre
        self.startYear = startYear
        self.endYear = endYear
        self.unwatchedOnly = unwatchedOnly
        self.sort = sort
        self.limit = limit
    }

    /// True when the caller asked for the whole library. Those calls get a
    /// sample rather than the first N — twenty alphabetical titles out of three
    /// thousand look like an answer and are noise. A sort or a limit makes the
    /// call a ranking question, which must stay deterministic: "top 10 by
    /// rating" answered with a random draw is a wrong answer, not flavour.
    public var isUnfiltered: Bool {
        title.isEmpty && genre.isEmpty && startYear == nil && endYear == nil
            && !unwatchedOnly && sort == nil && limit == nil
    }
}

/// One sort key for the library list tools. Wire form is `field` or
/// `field.asc` / `field.desc` ("rating", "year.asc", …) — dotted like TMDB's
/// sort keys, so the model carries one convention across tools.
public struct LibrarySort: Sendable, Equatable {
    public enum Field: String, Sendable {
        case rating, year, added, title, random
    }
    public var field: Field
    public var ascending: Bool

    public init(field: Field, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }

    /// nil for unknown fields — the tool reports the vocabulary instead of
    /// silently ignoring a typo'd sort.
    public static func parse(_ raw: String) -> LibrarySort? {
        let parts = raw.lowercased().split(separator: ".", maxSplits: 1).map(String.init)
        guard let first = parts.first, let field = Field(rawValue: first) else { return nil }
        let defaultAscending = (field == .title)
        let ascending: Bool
        switch parts.count > 1 ? parts[1] : "" {
        case "asc": ascending = true
        case "desc": ascending = false
        default: ascending = defaultAscending
        }
        return LibrarySort(field: field, ascending: ascending)
    }
}

/// A library record, seen through the only fields filtering needs.
public protocol LibraryFilterable {
    var filterTitle: String { get }
    var filterYear: Int? { get }
    var filterGenres: [String] { get }
    var filterRating: Double? { get }
    /// ISO-8601 date the arr added the record, as shipped on the wire.
    /// Lexicographic order IS chronological order for these strings.
    var filterAdded: String? { get }
}

extension RadarrLibraryRecord: LibraryFilterable {
    public var filterTitle: String { title ?? "" }
    public var filterYear: Int? { year }
    public var filterGenres: [String] { genres ?? [] }
    public var filterRating: Double? { ratings?.tmdb?.value ?? ratings?.imdb?.value }
    public var filterAdded: String? { added }
}

extension SonarrLibraryRecord: LibraryFilterable {
    public var filterTitle: String { title ?? "" }
    public var filterYear: Int? { year }
    public var filterGenres: [String] { genres ?? [] }
    public var filterRating: Double? { ratings?.value }
    public var filterAdded: String? { added }
}

public enum LibraryFilter {

    /// Apply a query to a library. `isWatched` is injected rather than read
    /// from `MediaServerIndex` inside, so the rule is testable without a
    /// media server and so a caller with no server connected can pass a
    /// closure that admits it doesn't know.
    public static func apply<T: LibraryFilterable>(
        _ records: [T],
        query: LibraryQuery,
        isWatched: (T) -> Bool
    ) -> [T] {
        var out = records
        if !query.genre.isEmpty {
            let wanted = TitleMatch.normalize(query.genre)
            out = out.filter { rec in
                rec.filterGenres.contains { TitleMatch.normalize($0).contains(wanted) }
            }
        }
        if let from = query.startYear {
            out = out.filter { ($0.filterYear ?? 0) >= from }
        }
        if let to = query.endYear {
            out = out.filter { ($0.filterYear ?? 9999) <= to }
        }
        if query.unwatchedOnly {
            out = out.filter { !isWatched($0) }
        }
        // Title next: it re-orders by match quality, and the facet filters
        // above only ever remove, so running it after keeps that order intact.
        if !query.title.isEmpty {
            out = TitleMatch.matches(query: query.title, candidates: out, title: \.filterTitle)
        }
        // An explicit sort always wins — it is the caller's question ("top 10
        // by rating" has one correct order).
        if let sort = query.sort {
            return sorted(out, by: sort)
        }
        if !query.title.isEmpty { return out }
        // No title and no sort: rank by what the caller is actually asking
        // for: "unwatched sci-fi I own" wants the good ones first, and the arr's
        // own alphabetical order buries them under whatever starts with A.
        // Unrated titles sort as average rather than last — an arr that never
        // fetched a rating is not evidence the film is bad.
        return out.sorted { ($0.filterRating ?? 6.0) > ($1.filterRating ?? 6.0) }
    }

    /// Deterministic ordering for one sort key (except `.random`, whose whole
    /// point is a fresh draw). Ties break on title so equal-rated rows don't
    /// flap between calls.
    static func sorted<T: LibraryFilterable>(_ records: [T], by sort: LibrarySort) -> [T] {
        func tie(_ a: T, _ b: T) -> Bool { a.filterTitle < b.filterTitle }
        switch sort.field {
        case .random:
            return records.shuffled()
        case .title:
            return records.sorted {
                sort.ascending ? $0.filterTitle < $1.filterTitle : $0.filterTitle > $1.filterTitle
            }
        case .rating:
            return records.sorted {
                let l = $0.filterRating ?? 6.0, r = $1.filterRating ?? 6.0
                if l != r { return sort.ascending ? l < r : l > r }
                return tie($0, $1)
            }
        case .year:
            return records.sorted {
                let l = $0.filterYear ?? 0, r = $1.filterYear ?? 0
                if l != r { return sort.ascending ? l < r : l > r }
                return tie($0, $1)
            }
        case .added:
            // ISO-8601 strings order lexicographically; missing dates sort as
            // oldest either way.
            return records.sorted {
                let l = $0.filterAdded ?? "", r = $1.filterAdded ?? ""
                if l != r { return sort.ascending ? l < r : l > r }
                return tie($0, $1)
            }
        }
    }

    /// A spread across the library for unfiltered calls. Uniformly random, and
    /// that word is load-bearing.
    ///
    /// This used to be rating-weighted (score = rating + jitter), which sounds
    /// harmless and was not: on a curated library the top of the rating curve
    /// is one taste — Asian arthouse, say — so every draw returned nearly the
    /// same forty films. The model reads the sample as a portrait of the user,
    /// concludes their taste IS that corner, and recommends more of it forever.
    /// A biased sample doesn't just mislead the one call; it feeds a profile
    /// that shapes everything downstream.
    ///
    /// So: every title equally likely, a different draw each time. A sample of
    /// a shelf should look like the shelf, not like its top decile.
    public static func sample<T>(_ records: [T], count: Int) -> [T] {
        guard records.count > count else { return records }
        return Array(records.shuffled().prefix(count))
    }

    /// Titles closest to a query that matched nothing. An empty answer reads as
    /// "you don't own it", which is the worst thing this app can say wrongly —
    /// so a miss always comes back with the nearest few instead.
    public static func nearest<T: LibraryFilterable>(
        to query: String,
        in records: [T],
        limit: Int = 3
    ) -> [T] {
        let normalized = TitleMatch.normalize(query)
        guard !normalized.isEmpty else { return [] }
        return records
            .map { ($0, TitleMatch.editDistance(normalized, TitleMatch.normalize($0.filterTitle), limit: 8)) }
            .filter { $0.1 <= 8 }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
