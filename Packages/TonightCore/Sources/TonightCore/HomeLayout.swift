import Foundation
import MediaKit

/// One shelf that can appear on Home. The catalogue is closed and ordered by
/// `allCases`, which doubles as the default Home layout — Settings only
/// reorders and hides these, never invents new ones.
public enum HomeSectionKind: String, CaseIterable, Identifiable, Sendable {
    case trendingMovies
    case trendingSeries
    case inTheaters
    case onTheAir
    case popularMovies
    case popularSeries
    case topRatedMovies
    case topRatedSeries
    /// The user's own watchlists, one shelf each. Always last by default.
    case myLists

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .trendingMovies: return String(localized: "Trending Movies", bundle: .module)
        case .trendingSeries: return String(localized: "Trending Series", bundle: .module)
        case .inTheaters: return String(localized: "In Theaters", bundle: .module)
        case .onTheAir: return String(localized: "On The Air", bundle: .module)
        case .popularMovies: return String(localized: "Popular Movies", bundle: .module)
        case .popularSeries: return String(localized: "Popular Series", bundle: .module)
        case .topRatedMovies: return String(localized: "Top Rated Movies", bundle: .module)
        case .topRatedSeries: return String(localized: "Top Rated Series", bundle: .module)
        case .myLists: return String(localized: "My Lists", bundle: .module)
        }
    }

    public var symbol: String {
        switch self {
        case .trendingMovies, .popularMovies, .topRatedMovies: return "film"
        case .trendingSeries, .popularSeries, .topRatedSeries: return "tv"
        case .inTheaters: return "popcorn"
        case .onTheAir: return "antenna.radiowaves.left.and.right"
        case .myLists: return "rectangle.stack"
        }
    }

    /// Wide 16:9 backdrop cards for the "what's on right now" shelves; the
    /// evergreen catalogue shelves stay classic posters.
    public var wide: Bool {
        switch self {
        case .trendingMovies, .trendingSeries, .inTheaters, .onTheAir: return true
        default: return false
        }
    }

    /// The shelf as a question for the data layer. `nil` for shelves built
    /// from local data — My Lists lives in SwiftData, not on a server.
    public var query: MediaCatalogQuery? {
        switch self {
        case .trendingMovies: MediaCatalogQuery(.trending(window: .week), kind: .movie)
        case .trendingSeries: MediaCatalogQuery(.trending(window: .week), kind: .series)
        case .inTheaters: MediaCatalogQuery(.curated(.nowPlaying), kind: .movie)
        case .onTheAir: MediaCatalogQuery(.curated(.onTheAir), kind: .series)
        case .popularMovies: MediaCatalogQuery(.curated(.popular), kind: .movie)
        case .popularSeries: MediaCatalogQuery(.curated(.popular), kind: .series)
        case .topRatedMovies: MediaCatalogQuery(.curated(.topRated), kind: .movie)
        case .topRatedSeries: MediaCatalogQuery(.curated(.topRated), kind: .series)
        case .myLists: nil
        }
    }
}

/// What the Home marquee cycles through.
public enum HomeHeroKind: String, CaseIterable, Identifiable, Sendable {
    case movies
    case series
    case mix

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .movies: return String(localized: "Movies", bundle: .module)
        case .series: return String(localized: "Series", bundle: .module)
        case .mix: return String(localized: "Mix", bundle: .module)
        }
    }
}
