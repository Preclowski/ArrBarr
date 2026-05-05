import Foundation

// MARK: - Shared

struct QualityProfile: Decodable, Identifiable {
    let id: Int
    let name: String
}

struct RootFolder: Decodable, Identifiable {
    let id: Int
    let path: String
}

// MARK: - Search result (unified)

struct SearchResult: Identifiable, Equatable, Sendable {
    let id: Int                  // arr's internal id (tmdbId for Radarr, tvdbId for Sonarr)
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
}

// MARK: - Monitor modes

enum RadarrMonitorMode: String, CaseIterable, Identifiable {
    case movieOnly, movieAndCollection, none
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .movieOnly: return "Movie Only"
        case .movieAndCollection: return "Movie & Collection"
        case .none: return "None"
        }
    }
}

enum SonarrMonitorMode: String, CaseIterable, Identifiable {
    case all, future, missing, existing, first, latest, none
    var id: String { rawValue }
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

enum SonarrSeriesType: String, CaseIterable, Identifiable {
    case standard, daily, anime
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}
