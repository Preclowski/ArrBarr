import Foundation

/// A browse filter: everything the advanced-filter sidebar can express,
/// mapped to TMDB `/discover` query items. Codable so a filter can later be
/// saved as a smart list.
public struct DiscoverFilter: Codable, Hashable, Sendable {
    public var type: MediaType = .movie
    /// Multi-select — TMDB ANDs them together (`with_genres=28,878`).
    public var genreIds: Set<Int> = []
    public var startYear: Int? = nil
    public var endYear: Int? = nil
    public var minRating: Double? = nil
    /// Vote floor on top of the sort's own baseline — the honest way to keep
    /// obscure five-vote titles out of a "highest rated" list.
    public var minVotes: Int? = nil
    public var maxRuntime: Int? = nil
    /// Multi-select — TMDB ORs providers (`with_watch_providers=8|337`).
    public var providerIds: Set<Int> = []
    public var language: String? = nil
    /// Client-side filter against the user's own library (Plex/Radarr/…).
    public var libraryPresence: LibraryPresence = .all
    public var sort: Sort = .popularity

    public enum LibraryPresence: String, Codable, CaseIterable, Sendable, Identifiable {
        case all
        case owned
        case notOwned

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            // One word each, and named after the intent rather than the
            // negation: "Discover" is what a person is doing when they ask
            // for the things they do not have yet.
            case .all: return String(localized: "All", bundle: .module)
            case .owned: return String(localized: "Library", bundle: .module)
            case .notOwned: return String(localized: "Discover", bundle: .module)
            }
        }
    }

    public enum Sort: String, Codable, CaseIterable, Sendable, Identifiable {
        case popularity
        case rating
        case newest
        case votes

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .popularity: return String(localized: "Popularity", bundle: .module)
            case .rating: return String(localized: "Rating", bundle: .module)
            case .newest: return String(localized: "Newest", bundle: .module)
            case .votes: return String(localized: "Most Voted", bundle: .module)
            }
        }

        public var symbol: String {
            switch self {
            case .popularity: return "flame"
            case .rating: return "star"
            case .newest: return "calendar"
            case .votes: return "person.3"
            }
        }
    }

    public init(type: MediaType = .movie) { self.type = type }

    public var isDefault: Bool { activeCount == 0 && sort == .popularity }

    /// How many filters are switched on — the badge on the Filters button and
    /// the number of tokens under the header. The library scope is
    /// deliberately not counted: it is the page's scope, not a filter, and it
    /// has a control of its own that always says what it is doing.
    public var activeCount: Int {
        var n = 0
        if !genreIds.isEmpty { n += 1 }
        if startYear != nil || endYear != nil { n += 1 }
        if minRating != nil { n += 1 }
        if minVotes != nil { n += 1 }
        if maxRuntime != nil { n += 1 }
        if !providerIds.isEmpty { n += 1 }
        if language != nil { n += 1 }
        return n
    }

    func queryItems(region: String) -> [URLQueryItem] {
        var q: [URLQueryItem] = [
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "watch_region", value: region),
        ]
        // Each sort carries the vote floor that makes it meaningful; an
        // explicit `minVotes` overrides it.
        var voteFloor: Int
        switch sort {
        case .popularity:
            q.append(URLQueryItem(name: "sort_by", value: "popularity.desc"))
            voteFloor = type == .movie ? 50 : 20
        case .rating:
            q.append(URLQueryItem(name: "sort_by", value: "vote_average.desc"))
            voteFloor = 300
        case .newest:
            q.append(URLQueryItem(name: "sort_by", value: type == .movie
                ? "primary_release_date.desc" : "first_air_date.desc"))
            voteFloor = 20
        case .votes:
            q.append(URLQueryItem(name: "sort_by", value: "vote_count.desc"))
            voteFloor = 0
        }
        if let minVotes { voteFloor = max(voteFloor, minVotes) }
        if voteFloor > 0 {
            q.append(URLQueryItem(name: "vote_count.gte", value: String(voteFloor)))
        }
        if !genreIds.isEmpty {
            q.append(URLQueryItem(name: "with_genres",
                                  value: genreIds.sorted().map(String.init).joined(separator: ",")))
        }
        let dateKey = type == .movie ? "primary_release_date" : "first_air_date"
        if let startYear {
            q.append(URLQueryItem(name: "\(dateKey).gte", value: "\(startYear)-01-01"))
        }
        if let endYear {
            q.append(URLQueryItem(name: "\(dateKey).lte", value: "\(endYear)-12-31"))
        }
        if let minRating {
            q.append(URLQueryItem(name: "vote_average.gte", value: String(minRating)))
        }
        if let maxRuntime {
            q.append(URLQueryItem(name: "with_runtime.lte", value: String(maxRuntime)))
        }
        if !providerIds.isEmpty {
            q.append(URLQueryItem(name: "with_watch_providers",
                                  value: providerIds.sorted().map(String.init).joined(separator: "|")))
        }
        if let language {
            q.append(URLQueryItem(name: "with_original_language", value: language))
        }
        return q
    }

    // MARK: - Local collections

    /// The client-side counterpart of the discover query, for collections the
    /// app already holds (the Quiz log, lists, watched). Runtime, providers
    /// and language have no answer in a stored snapshot — the sidebar hides
    /// those sections for local collections, and they are ignored here.
    /// The media type is NOT checked here: a local page may deliberately show
    /// movies and series together, and scopes them itself.
    public func matches(_ item: MediaItem) -> Bool {
        if !genreIds.isEmpty, !genreIds.isSubset(of: Set(item.genreIds)) { return false }
        if let startYear, (item.year ?? 0) < startYear { return false }
        if let endYear, (item.year ?? Int.max) > endYear { return false }
        if let minRating, (item.rating ?? 0) < minRating { return false }
        if let minVotes, (item.voteCount ?? 0) < minVotes { return false }
        return true
    }

}

/// What a page is *pinned* to: the part of the filter that is the page's own
/// identity rather than something the user switched on. A genre page pins its
/// genre, a decade page pins its years. Pinned values are named in the page
/// title, never drawn as a removable token, and survive Clear All / Reset All
/// — otherwise one click turns "Western" or "The 1980s" into all of TMDB
/// while the header still claims otherwise.
public struct FilterPreset: Hashable, Sendable {
    public var genreIds: Set<Int> = []
    public var years: ClosedRange<Int>? = nil

    public static let none = FilterPreset()

    public init(genreIds: Set<Int> = [], years: ClosedRange<Int>? = nil) {
        self.genreIds = genreIds
        self.years = years
    }

    public var isEmpty: Bool { genreIds.isEmpty && years == nil }

    /// Whether the filter's years are exactly the pinned ones — the year
    /// token is the page's identity then, not a filter of its own.
    func ownsYears(of filter: DiscoverFilter) -> Bool {
        guard let years else { return false }
        return filter.startYear == years.lowerBound && filter.endYear == years.upperBound
    }

    /// How many filters the *user* switched on. What the page is pinned to
    /// is not one of them: a decade page opened with a badge reading "1" and
    /// a Reset button lit up over a filter nobody had set.
    func userCount(in filter: DiscoverFilter) -> Int {
        var n = filter.activeCount
        if !genreIds.isEmpty, filter.genreIds == genreIds { n -= 1 }
        if ownsYears(of: filter) { n -= 1 }
        return max(0, n)
    }

    /// The filter this page starts from, and the one Reset goes back to: a
    /// clean filter with the pin put back, keeping what is not a filter at
    /// all (the library scope and the sort).
    func applied(to filter: DiscoverFilter) -> DiscoverFilter {
        var reset = DiscoverFilter(type: filter.type)
        reset.genreIds = genreIds
        reset.startYear = years?.lowerBound
        reset.endYear = years?.upperBound
        reset.libraryPresence = filter.libraryPresence
        reset.sort = filter.sort
        return reset
    }
}

/// TMDB genre catalogs, used for the filter sidebar, the Genres section and
/// for rendering `genre_ids`.
public enum Genres {
    public static let movie: [(id: Int, name: String)] = [
        (28, "Action"), (12, "Adventure"), (16, "Animation"), (35, "Comedy"),
        (80, "Crime"), (99, "Documentary"), (18, "Drama"), (10751, "Family"),
        (14, "Fantasy"), (36, "History"), (27, "Horror"), (10402, "Music"),
        (9648, "Mystery"), (10749, "Romance"), (878, "Science Fiction"),
        (53, "Thriller"), (10752, "War"), (37, "Western"),
    ]
    public static let tv: [(id: Int, name: String)] = [
        (10759, "Action & Adventure"), (16, "Animation"), (35, "Comedy"),
        (80, "Crime"), (99, "Documentary"), (18, "Drama"), (10751, "Family"),
        (10762, "Kids"), (9648, "Mystery"), (10763, "News"), (10764, "Reality"),
        (10765, "Sci-Fi & Fantasy"), (10766, "Soap"), (10767, "Talk"),
        (10768, "War & Politics"), (37, "Western"),
    ]

    public static func list(for type: MediaType) -> [(id: Int, name: String)] {
        type == .movie ? movie : tv
    }

    public static func name(for id: Int, type: MediaType) -> String? {
        list(for: type).first { $0.id == id }?.name
            ?? movie.first { $0.id == id }?.name
            ?? tv.first { $0.id == id }?.name
    }

    /// The genres of a kind as navigation values — what the Discover row is
    /// made of.
    public static func refs(for type: MediaType) -> [GenreRef] {
        list(for: type).map { GenreRef(id: $0.id, type: type) }
    }

    /// The mark a genre wears where it has no artwork of its own — the
    /// Discover tiles. Keyed by TMDB id, so the two catalogs share what they
    /// have in common (16 Animation, 35 Comedy, 18 Drama…).
    public static func symbol(for id: Int, type: MediaType) -> String {
        switch id {
        case 28, 10759: return "flame"          // Action / Action & Adventure
        case 12: return "map"                   // Adventure
        case 16: return "pawprint"              // Animation
        case 35: return "face.smiling"          // Comedy
        case 80: return "shield.lefthalf.filled" // Crime
        case 99: return "camera"                // Documentary
        case 18: return "theatermasks"          // Drama
        case 10751: return "person.2"           // Family
        case 14, 10765: return "wand.and.stars" // Fantasy / Sci-Fi & Fantasy
        case 36: return "building.columns"      // History
        case 27: return "moon"                  // Horror
        case 10402: return "music.note"         // Music
        case 9648: return "magnifyingglass"     // Mystery
        case 10749: return "heart"              // Romance
        case 878: return "atom"                 // Science Fiction
        case 53: return "bolt"                  // Thriller
        case 10752, 10768: return "shield"      // War / War & Politics
        case 37: return "sun.horizon"           // Western
        case 10762: return "balloon"            // Kids
        case 10763: return "newspaper"          // News
        case 10764: return "video"              // Reality
        case 10766: return "drop"               // Soap
        case 10767: return "mic"                // Talk
        default: return type == .movie ? "film" : "tv"
        }
    }

    /// Localized genre name — the catalogs above stay English (they mirror
    /// TMDB's ids), the UI shows this.
    public static func displayName(for id: Int, type: MediaType) -> String {
        guard let english = name(for: id, type: type) else { return "" }
        return String(localized: String.LocalizationValue(english), bundle: .module)
    }
}

/// The streaming services offered by the filter sidebar. TMDB provider ids
/// are global; availability is narrowed by `watch_region`.
public enum StreamingProviders {
    public static let all: [(id: Int, name: String)] = [
        (8, "Netflix"),
        (119, "Amazon Prime Video"),
        (337, "Disney+"),
        (350, "Apple TV+"),
        (1899, "Max"),
        (1773, "SkyShowtime"),
    ]

    public static func name(for id: Int) -> String? {
        all.first { $0.id == id }?.name
    }
}

/// Original-language choices for the filter sidebar (ISO 639-1).
public enum FilterLanguages {
    public static let all = ["en", "pl", "fr", "de", "es", "it", "ja", "ko"]

    public static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }
}
