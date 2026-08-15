import Foundation

// MARK: - Shared

public struct QualityProfile: Decodable, Identifiable, Sendable {
    public let id: Int
    let name: String
}

public struct RootFolder: Decodable, Identifiable {
    public let id: Int
    let path: String
}

// MARK: - Search result (unified)

public struct SearchResult: Identifiable, Equatable, Hashable, Sendable {
    public let id: Int                  // arr's internal id (tmdbId for Radarr, tvdbId for Sonarr)
    let foreignId: String        // tmdbId/tvdbId as string — used in POST body
    let title: String
    let subtitle: String?        // nil for movies; "X seasons" for shows
    let year: Int?
    let rating: Double?          // primary score (TMDB for Radarr, value for Sonarr)
    /// Vote count for the primary rating. Radarr-only — Sonarr's
    /// lookup ratings object is just `{ value: Double }`. Drives the
    /// Bayesian-quality tie-breaker in `SearchRelevance` (a 9.9-rated
    /// film with 5 votes gets pulled toward the global mean; an 8.0
    /// with 20 000 stays put). Nil for sources without vote data,
    /// where the relevance scorer falls back to the raw rating.
    let votes: Int?
    let imdb: Double?            // Radarr only
    let rottenTomatoes: Double?  // Radarr only
    let metacritic: Double?      // Radarr only
    /// `"ttNNNNNNN"` when the source reports one (Radarr / Sonarr). The
    /// unified identity is TMDB/TVDB-keyed, so this is the ONLY thing an
    /// `imdb:ttN` query can match on.
    let imdbId: String?
    /// Zero-based position in the arr's own `/lookup` response. That order
    /// encodes upstream popularity (TMDB / TVDB rank it for us), which the
    /// ranker used to discard wholesale by re-sorting on a continuous
    /// score that essentially never ties. Kept as a mild ranking signal.
    let sourceRank: Int
    let overview: String?
    let runtime: Int?            // minutes
    let genres: [String]
    let network: String?         // Sonarr network / Radarr studio
    let certification: String?   // Radarr only
    let posterURL: URL?
    let source: QueueItem.Source
    /// Set when the backend has cross-referenced this result with the arr's
    /// library and found a match. Carries the arr's internal record id so the
    /// chat UI can route a tap to DetailView instead of the add flow.
    /// `nil` for non-cross-referenced results (e.g. regular `*_search` calls).
    let inLibraryArrId: Int?
    /// Lidarr only: true when this row is an ALBUM (`/album/lookup`), false
    /// for artists (`/artist/lookup`). The two route differently on tap —
    /// albums open/add the album, artists open the artist view — and the two
    /// lookups return records with disjoint shapes, so the flag is stamped at
    /// unify time rather than re-derived downstream.
    let isLidarrAlbum: Bool

    init(id: Int, foreignId: String, title: String, subtitle: String?,
         year: Int?, rating: Double?, votes: Int? = nil,
         imdb: Double?, rottenTomatoes: Double?,
         metacritic: Double?, overview: String?, runtime: Int?,
         genres: [String], network: String?, certification: String?,
         posterURL: URL?, source: QueueItem.Source,
         inLibraryArrId: Int? = nil,
         imdbId: String? = nil, sourceRank: Int = 0,
         isLidarrAlbum: Bool = false) {
        self.id = id
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
    }

    /// Re-stamp `inLibraryArrId` without retyping every other field.
    /// Used by tools (suggest_titles, *_search) that resolve results
    /// first and then cross-reference against a library map.
    func withInLibraryArrId(_ id: Int?) -> SearchResult {
        SearchResult(
            id: self.id, foreignId: self.foreignId,
            title: self.title, subtitle: self.subtitle,
            year: self.year, rating: self.rating, votes: self.votes,
            imdb: self.imdb, rottenTomatoes: self.rottenTomatoes,
            metacritic: self.metacritic,
            overview: self.overview, runtime: self.runtime,
            genres: self.genres, network: self.network,
            certification: self.certification,
            posterURL: self.posterURL, source: self.source,
            inLibraryArrId: id,
            imdbId: self.imdbId, sourceRank: self.sourceRank,
            isLidarrAlbum: self.isLidarrAlbum
        )
    }
}

// MARK: - Monitor modes

public enum RadarrMonitorMode: String, CaseIterable, Identifiable {
    case movieOnly, movieAndCollection, none
    public var id: String { rawValue }
    /// Localized through the catalog, not returned raw. A bare English string
    /// here reaches the UI via `Text(someString)`, which takes the
    /// *non-localizing* StringProtocol overload — so the catalog is never
    /// consulted and the label stays English in every language.
    var displayName: String {
        switch self {
        case .movieOnly: return String(localized: "search.movieOnly.button", bundle: .module)
        case .movieAndCollection: return String(localized: "search.movieAndCollection.button", bundle: .module)
        case .none: return String(localized: "search.none.button", bundle: .module)
        }
    }
}

public enum SonarrMonitorMode: String, CaseIterable, Identifiable {
    case all, future, missing, existing, first, latest, none
    public var id: String { rawValue }
    /// Value Sonarr expects for `addOptions.monitor`. Sonarr's
    /// `MonitorTypes` enum serialises to camelCase (`firstSeason`,
    /// `latestSeason`) — sending our short `first`/`latest` raw values
    /// makes Sonarr reject the POST with HTTP 400 ("could not be converted
    /// to NzbDrone.Core.Tv.MonitorTypes"). The rest map 1:1.
    var apiValue: String {
        switch self {
        case .first: return "firstSeason"
        case .latest: return "latestSeason"
        default: return rawValue
        }
    }
    /// See `RadarrMonitorMode.displayName` — localized, not raw.
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

/// Lidarr `addOptions.monitor` for a new artist. Mirrors Lidarr's
/// `MonitorTypes` (serialised lowercase/camelCase 1:1 — unlike Sonarr,
/// `first`/`latest` need no remapping).
public enum LidarrMonitorMode: String, CaseIterable, Identifiable {
    case all, future, missing, existing, first, latest, none
    public var id: String { rawValue }
    /// See `RadarrMonitorMode.displayName` — localized, not raw.
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

/// Radarr's `minimumAvailability` — when a monitored movie becomes eligible
/// for searching/downloading. Serialises 1:1 to Radarr v3's enum values.
public enum RadarrMinimumAvailability: String, CaseIterable, Identifiable {
    case announced, inCinemas, released
    public var id: String { rawValue }
    /// See `RadarrMonitorMode.displayName` — localized, not raw.
    var displayName: String {
        switch self {
        case .announced: return String(localized: "edit.availability.announced.button", bundle: .module)
        case .inCinemas: return String(localized: "edit.availability.inCinemas.button", bundle: .module)
        case .released: return String(localized: "edit.availability.released.button", bundle: .module)
        }
    }
}

public enum SonarrSeriesType: String, CaseIterable, Identifiable {
    case standard, daily, anime
    public var id: String { rawValue }
    /// Was `rawValue.capitalized` — cheap, and English-only forever: a
    /// capitalized raw value can't be translated because it never existed as a
    /// catalog key. See `RadarrMonitorMode.displayName`.
    var displayName: String {
        switch self {
        case .standard: return String(localized: "search.standard.button", bundle: .module)
        case .daily: return String(localized: "search.daily.button", bundle: .module)
        case .anime: return String(localized: "search.anime.button", bundle: .module)
        }
    }
}
