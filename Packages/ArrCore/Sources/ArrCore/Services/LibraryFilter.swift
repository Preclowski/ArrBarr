import Foundation
import MediaKit

/// Facets are spelled like `tmdb_discover_*` so the model has one vocabulary. No exclude-genre filter:
/// tags can't answer "romantic but not a drama", so genres travel in every row and the model judges.
nonisolated public struct LibraryQuery: Sendable, Equatable {
    public var title: String
    public var genre: String
    public var startYear: Int?
    public var endYear: Int?
    public var unwatchedOnly: Bool
    /// nil keeps title-match order, else rating-desc.
    public var sort: LibrarySort?
    /// The tool still applies its own hard cap on top; this makes "top 10" return 10 rows.
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

    /// Whole-library calls get a sample, not the first N alphabetical titles. A sort or limit makes it a
    /// ranking question, which must stay deterministic.
    public var isUnfiltered: Bool {
        title.isEmpty && genre.isEmpty && startYear == nil && endYear == nil
            && !unwatchedOnly && sort == nil && limit == nil
    }
}

/// Wire form is `field` or `field.asc` / `field.desc`, dotted like TMDB's sort keys.
nonisolated public struct LibrarySort: Sendable, Equatable {
    public enum Field: String, Sendable {
        case rating, year, added, title, random
    }
    public var field: Field
    public var ascending: Bool

    public init(field: Field, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }

    /// nil for unknown fields, so the tool can report the vocabulary instead of ignoring a typo.
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

nonisolated public protocol LibraryFilterable {
    var filterTitle: String { get }
    var filterYear: Int? { get }
    var filterGenres: [String] { get }
    var filterRating: Double? { get }
    /// ISO-8601 as shipped; lexicographic order is chronological.
    var filterAdded: String? { get }
}

nonisolated extension ArrMovie: LibraryFilterable {
    public var filterTitle: String { title }
    public var filterYear: Int? { year }
    public var filterGenres: [String] { genres ?? [] }
    public var filterRating: Double? { ratings?.tmdb?.value ?? ratings?.imdb?.value }
    public var filterAdded: String? { added }
}

nonisolated extension ArrSeries: LibraryFilterable {
    public var filterTitle: String { title }
    public var filterYear: Int? { year }
    public var filterGenres: [String] { genres ?? [] }
    public var filterRating: Double? { ratings?.value }
    public var filterAdded: String? { added }
}

nonisolated enum LibraryFilter {

    /// `isWatched` is injected so the rule is testable and a caller without a media server can admit it doesn't know.
    static func apply<T: LibraryFilterable>(
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
        // Title after the facet filters, which only remove, so its match-quality order survives.
        if !query.title.isEmpty {
            out = TitleMatch.matches(query: query.title, candidates: out, title: \.filterTitle)
        }
        if let sort = query.sort {
            return sorted(out, by: sort)
        }
        if !query.title.isEmpty { return out }
        // No title and no sort: best first. Unrated titles sort as average — a missing rating is not evidence.
        return out.sorted { ($0.filterRating ?? 6.0) > ($1.filterRating ?? 6.0) }
    }

    /// Ties break on title so equal-rated rows don't flap between calls.
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

    /// Uniformly random on purpose: a rating-weighted draw returns the same top-decile corner every time,
    /// and the model reads that as the user's whole taste.
    static func sample<T>(_ records: [T], count: Int) -> [T] {
        guard records.count > count else { return records }
        return Array(records.shuffled().prefix(count))
    }

    /// A miss returns the nearest few: an empty answer reads as "you don't own it".
    static func nearest<T: LibraryFilterable>(
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
