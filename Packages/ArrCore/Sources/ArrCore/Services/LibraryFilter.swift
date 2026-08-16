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

    public init(title: String = "", genre: String = "",
                startYear: Int? = nil, endYear: Int? = nil,
                unwatchedOnly: Bool = false) {
        self.title = title
        self.genre = genre
        self.startYear = startYear
        self.endYear = endYear
        self.unwatchedOnly = unwatchedOnly
    }

    /// True when the caller asked for the whole library. Those calls get a
    /// sample rather than the first N — twenty alphabetical titles out of three
    /// thousand look like an answer and are noise.
    public var isUnfiltered: Bool {
        title.isEmpty && genre.isEmpty && startYear == nil && endYear == nil && !unwatchedOnly
    }
}

/// A library record, seen through the only fields filtering needs.
public protocol LibraryFilterable {
    var filterTitle: String { get }
    var filterYear: Int? { get }
    var filterGenres: [String] { get }
    var filterRating: Double? { get }
}

extension RadarrLibraryRecord: LibraryFilterable {
    public var filterTitle: String { title ?? "" }
    public var filterYear: Int? { year }
    public var filterGenres: [String] { genres ?? [] }
    public var filterRating: Double? { ratings?.tmdb?.value ?? ratings?.imdb?.value }
}

extension SonarrLibraryRecord: LibraryFilterable {
    public var filterTitle: String { title ?? "" }
    public var filterYear: Int? { year }
    public var filterGenres: [String] { genres ?? [] }
    public var filterRating: Double? { ratings?.value }
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
        // Title last: it re-orders by match quality, and the facet filters
        // above only ever remove, so running it last keeps that order intact.
        if !query.title.isEmpty {
            return TitleMatch.matches(query: query.title, candidates: out, title: \.filterTitle)
        }
        // No title to rank by, so rank by what the caller is actually asking
        // for: "unwatched sci-fi I own" wants the good ones first, and the arr's
        // own alphabetical order buries them under whatever starts with A.
        // Unrated titles sort as average rather than last — an arr that never
        // fetched a rating is not evidence the film is bad.
        return out.sorted { ($0.filterRating ?? 6.0) > ($1.filterRating ?? 6.0) }
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
