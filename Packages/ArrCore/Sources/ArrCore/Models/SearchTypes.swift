import Foundation

// MARK: - Shared

public struct QualityProfile: Decodable, Identifiable {
    public let id: Int
    let name: String
}

public struct RootFolder: Decodable, Identifiable {
    public let id: Int
    let path: String
}

// MARK: - Search result (unified)

public struct SearchResult: Identifiable, Equatable, Sendable {
    public let id: Int                  // arr's internal id (tmdbId for Radarr, tvdbId for Sonarr)
    let foreignId: String        // tmdbId/tvdbId as string — used in POST body
    let title: String
    let subtitle: String?        // nil for movies; "X seasons" for shows
    let year: Int?
    let rating: Double?          // primary score (TMDB for Radarr, value for Sonarr)
    let imdb: Double?            // Radarr only
    let rottenTomatoes: Double?  // Radarr only
    let metacritic: Double?      // Radarr only
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

    init(id: Int, foreignId: String, title: String, subtitle: String?,
         year: Int?, rating: Double?, imdb: Double?, rottenTomatoes: Double?,
         metacritic: Double?, overview: String?, runtime: Int?,
         genres: [String], network: String?, certification: String?,
         posterURL: URL?, source: QueueItem.Source,
         inLibraryArrId: Int? = nil) {
        self.id = id
        self.foreignId = foreignId
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.rating = rating
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
    }

    /// Re-stamp `inLibraryArrId` without retyping every other field.
    /// Used by tools (suggest_titles, *_search) that resolve results
    /// first and then cross-reference against a library map.
    func withInLibraryArrId(_ id: Int?) -> SearchResult {
        SearchResult(
            id: self.id, foreignId: self.foreignId,
            title: self.title, subtitle: self.subtitle,
            year: self.year, rating: self.rating,
            imdb: self.imdb, rottenTomatoes: self.rottenTomatoes,
            metacritic: self.metacritic,
            overview: self.overview, runtime: self.runtime,
            genres: self.genres, network: self.network,
            certification: self.certification,
            posterURL: self.posterURL, source: self.source,
            inLibraryArrId: id
        )
    }
}

// MARK: - Monitor modes

public enum RadarrMonitorMode: String, CaseIterable, Identifiable {
    case movieOnly, movieAndCollection, none
    public var id: String { rawValue }
    var displayName: String {
        switch self {
        case .movieOnly: return "Movie Only"
        case .movieAndCollection: return "Movie & Collection"
        case .none: return "None"
        }
    }
}

public enum SonarrMonitorMode: String, CaseIterable, Identifiable {
    case all, future, missing, existing, first, latest, none
    public var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "All"
        case .future: return "Future"
        case .missing: return "Missing"
        case .existing: return "Existing"
        case .first: return "First Season"
        case .latest: return "Latest Season"
        case .none: return "None"
        }
    }
}

public enum SonarrSeriesType: String, CaseIterable, Identifiable {
    case standard, daily, anime
    public var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}
