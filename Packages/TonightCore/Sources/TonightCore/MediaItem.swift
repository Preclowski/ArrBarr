import Foundation
import ArrCore

public enum MediaType: String, Codable, Sendable, CaseIterable, Identifiable {
    case movie
    case tv

    public var id: String { rawValue }
    public var displayName: String {
        self == .movie
            ? String(localized: "Movie", bundle: .module)
            : String(localized: "TV Series", bundle: .module)
    }
}

/// Unified lightweight title used by shelves, grids and search — one shape for
/// movies and TV so views don't branch on TMDB's two summary types.
public struct MediaItem: Identifiable, Hashable, Sendable {
    public let tmdbId: Int
    public let type: MediaType
    public let title: String
    public let year: Int?
    public let posterPath: String?
    public let backdropPath: String?
    public let rating: Double?
    public let voteCount: Int?
    public let overview: String?
    public let genreIds: [Int]

    public var id: String { "\(type.rawValue)-\(tmdbId)" }

    public var posterURL: URL? { TMDBClient.imageURL(path: posterPath, size: "w342") }
    public var largePosterURL: URL? { TMDBClient.imageURL(path: posterPath, size: "w500") }
    public var backdropURL: URL? { TMDBClient.imageURL(path: backdropPath, size: "w1280") }
    public var backdropCardURL: URL? { TMDBClient.imageURL(path: backdropPath, size: "w780") }

    public init(tmdbId: Int, type: MediaType, title: String, year: Int?,
                posterPath: String?, backdropPath: String?, rating: Double?,
                voteCount: Int?, overview: String?, genreIds: [Int] = []) {
        self.tmdbId = tmdbId
        self.type = type
        self.title = title
        self.year = year
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.rating = rating
        self.voteCount = voteCount
        self.overview = overview
        self.genreIds = genreIds
    }
}

extension MediaItem {
    init(_ m: TMDBMovieSummary, backdropPath: String? = nil) {
        self.init(tmdbId: m.id, type: .movie, title: m.title, year: m.year,
                  posterPath: m.posterPath, backdropPath: backdropPath,
                  rating: m.voteAverage, voteCount: m.voteCount,
                  overview: m.overview, genreIds: m.genreIds ?? [])
    }

    init(_ t: TMDBTVSummary, backdropPath: String? = nil) {
        self.init(tmdbId: t.id, type: .tv, title: t.name, year: t.year,
                  posterPath: t.posterPath, backdropPath: backdropPath,
                  rating: t.voteAverage, voteCount: t.voteCount,
                  overview: t.overview, genreIds: t.genreIds ?? [])
    }
}
