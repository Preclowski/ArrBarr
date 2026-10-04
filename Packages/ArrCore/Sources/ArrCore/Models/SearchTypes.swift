import Foundation

// MARK: - Shared

// MARK: - Search result (unified)

nonisolated public struct SearchResult: Identifiable, Equatable, Hashable, Sendable {
    /// tmdbId for Radarr/Whisparr, tvdbId for Sonarr, a hashed MusicBrainz id for Lidarr.
    /// Not the row identity (`id`): TMDB-sourced series leave it `0`.
    var externalId: Int
    var foreignId: String        // tmdbId/tvdbId as string — used in POST body
    let title: String
    let subtitle: String?        // nil for movies; "X seasons" for shows
    let year: Int?
    let rating: Double?          // primary score (TMDB for Radarr, value for Sonarr)
    /// Radarr-only: Sonarr's lookup ratings are just `{ value: Double }`. Feeds the Bayesian tie-breaker
    /// in `SearchRelevance`; nil falls back to the raw rating.
    let votes: Int?
    let imdb: Double?            // Radarr only
    let rottenTomatoes: Double?  // Radarr only
    let metacritic: Double?      // Radarr only
    /// The identity is TMDB/TVDB-keyed, so this is the only thing an `imdb:ttN` query can match on.
    let imdbId: String?
    /// Position in the arr's `/lookup` response, which encodes upstream popularity; a mild ranking signal.
    let sourceRank: Int
    let overview: String?
    let runtime: Int?            // minutes
    let genres: [String]
    let network: String?         // Sonarr network / Radarr studio
    let certification: String?   // Radarr only
    var posterURL: URL?
    /// The arr's `/MediaCover` route answers 401 without the API key; lookup artwork (TMDB/TVDB) is public.
    var posterRequiresAuth: Bool = false
    let source: QueueItem.Source
    /// The arr's record id when the result is already in the library, so a tap opens DetailView.
    var inLibraryArrId: Int?
    var libraryDownloaded: Bool = false
    /// The arr's `status` (`announced`, `inCinemas`, `ended`…); nil on a lean TMDB row until it's enriched.
    var releaseStatus: String?
    /// Lidarr only: album vs artist. Stamped at unify time because the two lookups return disjoint shapes.
    let isLidarrAlbum: Bool
    /// TMDB's series id, for `.sonarr` rows only. TMDB-sourced rows have no tvdbId, so this keeps the
    /// lookup exact; `SeriesIdentityResolver` uses it to verify a `tmdb:N` answer.
    let tmdbTVId: Int?

    init(externalId: Int, foreignId: String, title: String, subtitle: String?,
         year: Int?, rating: Double?, votes: Int? = nil,
         imdb: Double?, rottenTomatoes: Double?,
         metacritic: Double?, overview: String?, runtime: Int?,
         genres: [String], network: String?, certification: String?,
         posterURL: URL?, source: QueueItem.Source,
         inLibraryArrId: Int? = nil,
         imdbId: String? = nil, sourceRank: Int = 0,
         isLidarrAlbum: Bool = false,
         tmdbTVId: Int? = nil) {
        self.externalId = externalId
        self.foreignId = foreignId
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.rating = rating
        self.votes = votes
        self.imdb = imdb
        self.rottenTomatoes = rottenTomatoes
        self.metacritic = metacritic
        self.overview = overview
        self.runtime = runtime
        self.genres = genres
        self.network = network
        self.certification = certification
        self.posterURL = posterURL
        self.source = source
        self.inLibraryArrId = inLibraryArrId
        self.imdbId = imdbId
        self.sourceRank = sourceRank
        self.isLidarrAlbum = isLidarrAlbum
        self.tmdbTVId = tmdbTVId
    }

    /// The foreign key is not always known (a TMDB series has only a `tmdbtv:` ref); the title + year
    /// fallback is never used to look anything up.
    public var id: String {
        let ref = mediaRef
        guard ref.isAddressable else {
            return "\(source.rawValue):\(title.lowercased())|\(year ?? 0)"
        }
        return "\(source.rawValue):\(ref.urlString)"
    }

    /// Arr record id and downloaded state, always together; `nil` clears both. A mutating copy so a new
    /// property can't be silently dropped.
    func withLibraryOwnership(_ ownership: LibraryOwnership?) -> SearchResult {
        var copy = self
        copy.inLibraryArrId = ownership?.arrId
        copy.libraryDownloaded = ownership?.isDownloaded ?? false
        // One choice of cover for every row, whatever produced it: the library's, then the media server's by
        // identity (it may hold a title the arr doesn't), else the row's own.
        if let poster = ownership?.poster ?? MediaServerIndex.shared.posterURL(for: copy.mediaServerKeys),
           poster != copy.posterURL {
            copy.posterURL = poster
            copy.posterRequiresAuth = false
        }
        return copy
    }

    /// Enrichment swaps in the arr's record, whose poster differs; a changed image reads as a different show.
    func withArtwork(from row: SearchResult) -> SearchResult {
        guard let poster = row.posterURL else { return self }
        var copy = self
        copy.posterURL = poster
        return copy
    }

    /// Only for ids proven by `SeriesIdentityResolver`, never matched by title.
    func withTVDBId(_ tvdbId: Int) -> SearchResult {
        var copy = self
        copy.externalId = tvdbId
        copy.foreignId = String(tvdbId)
        return copy
    }
}

// MARK: - Monitor modes

nonisolated enum RadarrMonitorMode: String, CaseIterable, Identifiable {
    case movieOnly, movieAndCollection, none
    var id: String { rawValue }
    /// Localized here: `Text(someString)` takes the non-localizing overload, so a raw string stays English.
    var displayName: String {
        switch self {
        case .movieOnly: return String(localized: "search.movieOnly.button", bundle: .module)
        case .movieAndCollection: return String(localized: "search.movieAndCollection.button", bundle: .module)
        case .none: return String(localized: "search.none.button", bundle: .module)
        }
    }
}

nonisolated enum SonarrMonitorMode: String, CaseIterable, Identifiable {
    case all, future, missing, existing, first, latest, none
    var id: String { rawValue }
    /// Sonarr's `MonitorTypes` is camelCase (`firstSeason`, `latestSeason`); the raw values get a 400.
    var apiValue: String {
        switch self {
        case .first: return "firstSeason"
        case .latest: return "latestSeason"
        default: return rawValue
        }
    }
    var displayName: String {
        switch self {
        case .all: return String(localized: "search.all.button", bundle: .module)
        case .future: return String(localized: "search.future.button", bundle: .module)
        case .missing: return String(localized: "search.missing.button", bundle: .module)
        case .existing: return String(localized: "search.existing.button", bundle: .module)
        case .first: return String(localized: "search.firstSeason.button", bundle: .module)
        case .latest: return String(localized: "search.latestSeason.button", bundle: .module)
        case .none: return String(localized: "search.none.button", bundle: .module)
        }
    }
}

/// Lidarr's `MonitorTypes` serialise 1:1; unlike Sonarr, `first`/`latest` need no remapping.
nonisolated enum LidarrMonitorMode: String, CaseIterable, Identifiable {
    case all, future, missing, existing, first, latest, none
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return String(localized: "search.all.button", bundle: .module)
        case .future: return String(localized: "search.future.button", bundle: .module)
        case .missing: return String(localized: "search.missing.button", bundle: .module)
        case .existing: return String(localized: "search.existing.button", bundle: .module)
        case .first: return String(localized: "search.firstAlbum.button", bundle: .module)
        case .latest: return String(localized: "search.latestAlbum.button", bundle: .module)
        case .none: return String(localized: "search.none.button", bundle: .module)
        }
    }
}

/// Radarr's `minimumAvailability`: when a monitored movie becomes eligible for searching.
nonisolated enum RadarrMinimumAvailability: String, CaseIterable, Identifiable {
    case announced, inCinemas, released
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .announced: return String(localized: "edit.availability.announced.button", bundle: .module)
        case .inCinemas: return String(localized: "edit.availability.inCinemas.button", bundle: .module)
        case .released: return String(localized: "edit.availability.released.button", bundle: .module)
        }
    }
}

nonisolated enum SonarrSeriesType: String, CaseIterable, Identifiable {
    case standard, daily, anime
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .standard: return String(localized: "search.standard.button", bundle: .module)
        case .daily: return String(localized: "search.daily.button", bundle: .module)
        case .anime: return String(localized: "search.anime.button", bundle: .module)
        }
    }
}

// MARK: - Library entry → search row

nonisolated extension SearchResult {
    /// Owned by definition, so it arrives stamped with the Library tab's file state.
    init(libraryEntry e: LibraryEntry) {
        self.init(
            externalId: e.externalId ?? 0,
            foreignId: e.externalId.map(String.init) ?? "",
            title: e.title, subtitle: nil, year: e.year,
            rating: e.ratingTmdb ?? e.ratingArr,
            imdb: e.ratingImdb, rottenTomatoes: e.ratingRt, metacritic: e.ratingMetacritic,
            overview: e.overview, runtime: e.runtime, genres: e.genres,
            network: nil, certification: e.certification,
            posterURL: e.posterURL, source: e.source
        )
        self = withLibraryOwnership(LibraryOwnership(arrId: e.arrId, isDownloaded: e.state == .complete))
        // The grid's covers are the arr's own `/MediaCover` files behind the API key.
        self.posterRequiresAuth = e.posterRequiresAuth
        self.releaseStatus = e.releaseStatus
    }
}
