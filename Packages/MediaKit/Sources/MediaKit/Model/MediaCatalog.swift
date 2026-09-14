import Foundation

/// "Which titles?" — the other half of the layer.
///
/// A `MediaQuery` asks what is known about ONE title. A catalog query asks for
/// a LIST: what is trending, what matches these filters, what does this search
/// find, what is in the library. The two are different shapes and forcing one
/// through the other bends both — so this is its own type, answered by its own
/// providers, and the per-title fields are filled in afterwards by the graph.
///
/// Deliberately not TMDB-shaped, because ArrBarr has to fit in it too: its
/// Discover browses TMDB (trending / popular / similar / recommended), its
/// search hits the arrs' `lookup`, and its library browse is a catalog over
/// Radarr/Sonarr/Lidarr. Those are `intent` cases here, not a second API.
public struct MediaCatalogQuery: Hashable, Sendable {
    public var intent: MediaCatalogIntent
    /// Movies, series, albums… `nil` means "whatever the intent implies",
    /// which is how a multi-search answers with a mix.
    public var kind: MediaKind?
    public var filter: MediaFilter
    public var sort: MediaSort
    public var page: Int
    /// ISO region for release dates and streaming availability, and the
    /// language facts should come back in. Both apps carry a user setting for
    /// these; neither should hardcode one in a provider.
    public var region: String?
    public var language: String?

    public init(_ intent: MediaCatalogIntent,
                kind: MediaKind? = nil,
                filter: MediaFilter = MediaFilter(),
                sort: MediaSort = .popularity,
                page: Int = 1,
                region: String? = nil,
                language: String? = nil) {
        self.intent = intent
        self.kind = kind
        self.filter = filter
        self.sort = sort
        self.page = page
        self.region = region
        self.language = language
    }
}

public extension MediaCatalogQuery {
    /// This query as the source sees it — see `MediaFilter.ignoringPresence`.
    var ignoringPresence: MediaCatalogQuery {
        var copy = self
        copy.filter = filter.ignoringPresence
        return copy
    }
}

/// What the caller is asking for. One case per question a UI actually asks —
/// an open query language would have to be implemented by every provider, and
/// none of them can answer an arbitrary predicate anyway.
public enum MediaCatalogIntent: Hashable, Sendable {
    /// What is popular right now.
    case trending(window: TrendingWindow)
    /// The provider's own editorial lists.
    case curated(CuratedShelf)
    /// Filter-driven browsing — the filter is the query.
    case discover
    case search(String)
    /// More like this. ArrBarr's Discover leans on both.
    case similar(to: MediaIdentity)
    case recommendations(for: MediaIdentity)
    /// A named list: a TMDB list, a Plex collection, an arr tag.
    case list(MediaCollectionRef)
    /// Someone's filmography.
    case credits(person: Int)
    /// What the user already has. Served by the arr and media-server
    /// providers — this is ArrBarr's main screen and TonightBarr's
    /// "Watched"/"Owned" filters, and it must not go near TMDB.
    case library(LibraryScope)

    public enum TrendingWindow: String, Hashable, Sendable, Codable {
        case day, week
    }

    /// Editorial shelves both apps show. Named for what they mean rather than
    /// for a TMDB path, because an arr or a media server can answer some of
    /// them from its own data.
    public enum CuratedShelf: String, Hashable, Sendable, Codable, CaseIterable {
        case popular
        case topRated
        /// Films not yet released / series returning.
        case upcoming
        /// In cinemas now.
        case nowPlaying
        case airingToday
        case onTheAir
        /// Added to the user's library most recently — media servers and arrs
        /// only.
        case recentlyAdded
    }

    public enum LibraryScope: Hashable, Sendable {
        case all
        case watched
        case unwatched
        case downloaded
        case missing
    }
}

/// A named collection of titles that exists somewhere: a TMDB list, a Plex
/// collection, an arr tag. The id is the provider's own; `provider` says whose
/// it is, so two lists with id 5 from different sources can't collide.
public struct MediaCollectionRef: Hashable, Sendable, Identifiable {
    public let provider: ProviderID
    public let id: String
    public let name: String?
    public let count: Int?

    public init(provider: ProviderID, id: String, name: String? = nil, count: Int? = nil) {
        self.provider = provider
        self.id = id
        self.name = name
        self.count = count
    }
}

/// Everything both apps filter on today, as one closed shape.
///
/// Closed on purpose: a `[String: String]` escape hatch would let each app
/// grow its own dialect, and the first provider that ignored a key would fail
/// silently. A filter a provider cannot honour is reported, not dropped.
public struct MediaFilter: Hashable, Sendable {
    /// TMDB genre ids — the id space both apps already use.
    public var genreIDs: Set<Int>
    public var yearRange: ClosedRange<Int>?
    public var minRating: Double?
    public var minVotes: Int?
    public var maxRuntimeMinutes: Int?
    /// TMDB watch-provider ids, narrowed by the query's region.
    public var streamingProviderIDs: Set<Int>
    /// ISO 639-1 original language.
    public var originalLanguage: String?
    /// Whether the user already has it. The one filter no metadata service can
    /// answer — the graph resolves it against the library providers.
    public var presence: LibraryPresence
    public var includeAdult: Bool

    public enum LibraryPresence: String, Hashable, Sendable, Codable {
        case any, owned, notOwned, watched, unwatched
    }

    public init(genreIDs: Set<Int> = [], yearRange: ClosedRange<Int>? = nil,
                minRating: Double? = nil, minVotes: Int? = nil,
                maxRuntimeMinutes: Int? = nil, streamingProviderIDs: Set<Int> = [],
                originalLanguage: String? = nil, presence: LibraryPresence = .any,
                includeAdult: Bool = false) {
        self.genreIDs = genreIDs
        self.yearRange = yearRange
        self.minRating = minRating
        self.minVotes = minVotes
        self.maxRuntimeMinutes = maxRuntimeMinutes
        self.streamingProviderIDs = streamingProviderIDs
        self.originalLanguage = originalLanguage
        self.presence = presence
        self.includeAdult = includeAdult
    }

    public var isEmpty: Bool { self == MediaFilter() }

    /// The same filter as a source sees it: presence is the graph's to apply,
    /// so it is not part of what identifies a request.
    public var ignoringPresence: MediaFilter {
        var copy = self
        copy.presence = .any
        return copy
    }
}

public enum MediaSort: String, Hashable, Sendable, Codable, CaseIterable {
    case popularity
    case rating
    case newest
    case oldest
    case mostVoted
    case title
    /// Whatever order the source considers natural — a search's relevance, a
    /// list's own order. The default for anything the caller didn't sort.
    case natural
}

/// One page of an answer.
///
/// Items are snapshots, not bare ids: a list endpoint already carries titles,
/// artwork and scores, and throwing that away only to ask again per title is
/// the exact waste this layer exists to remove. Fields the list didn't carry
/// are simply absent, and the graph can top them up.
public struct MediaCatalogPage: Sendable {
    public var items: [MediaSnapshot]
    public var page: Int
    public var totalPages: Int?
    public var totalResults: Int?
    /// For sources that page by cursor rather than by number.
    public var nextCursor: String?
    public var provenance: Provenance
    /// Filters the provider could not apply. The caller decides whether to
    /// narrow the results itself or to tell the user — silently returning
    /// unfiltered results is how a "4K only" browse quietly stops meaning
    /// anything.
    public var unappliedFilters: [String]

    public init(items: [MediaSnapshot], page: Int = 1, totalPages: Int? = nil,
                totalResults: Int? = nil, nextCursor: String? = nil,
                provenance: Provenance, unappliedFilters: [String] = []) {
        self.items = items
        self.page = page
        self.totalPages = totalPages
        self.totalResults = totalResults
        self.nextCursor = nextCursor
        self.provenance = provenance
        self.unappliedFilters = unappliedFilters
    }

    public var hasMore: Bool {
        if let nextCursor { return !nextCursor.isEmpty }
        guard let totalPages else { return !items.isEmpty }
        return page < totalPages
    }

    public static func empty(_ provider: ProviderID) -> MediaCatalogPage {
        MediaCatalogPage(items: [], page: 1, totalPages: 0,
                         provenance: Provenance(provider: provider, fetchedAt: Date(),
                                                fromCache: false))
    }
}

/// A provider that can answer "which titles".
///
/// Separate from `MediaProvider` because the two questions have different
/// costs and different sources: TMDB can answer `discover` but knows nothing
/// about a library, and Radarr can list what you own but cannot rank what is
/// trending.
public protocol MediaCatalogProviding: MediaProvider {
    /// Whether this provider can serve a given query at all — the intent, the
    /// kind, and any filter it refuses to fake.
    func canServe(_ query: MediaCatalogQuery) -> Bool
    func catalog(_ query: MediaCatalogQuery) async throws -> MediaCatalogPage
}
