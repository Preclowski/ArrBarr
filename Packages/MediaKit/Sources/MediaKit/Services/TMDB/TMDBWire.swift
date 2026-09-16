import Foundation

public struct TMDBPerson: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let knownForDepartment: String?
    public let profilePath: String?
    public let popularity: Double?
    public let character: String?
    public let job: String?
    public let department: String?
    public let order: Int?
}

public struct TMDBPersonDetails: Codable, Sendable, Equatable, Hashable {
    public let id: Int
    public let name: String
    public let biography: String?
    public let birthday: String?
    public let deathday: String?
    public let placeOfBirth: String?
    public let profilePath: String?
    public let imdbId: String?
    public let knownForDepartment: String?
}

public struct TMDBMovieSummary: Codable, Sendable, Equatable, Hashable {
    public let id: Int
    public let title: String
    public let originalTitle: String?
    public let releaseDate: String?
    public let posterPath: String?
    public let backdropPath: String?
    public let voteAverage: Double?
    public let voteCount: Int?
    public let popularity: Double?
    public let overview: String?
    public let genreIds: [Int]?
    public let character: String?
    public let department: String?
    public let job: String?
}

public struct TMDBTVSummary: Codable, Sendable, Equatable, Hashable {
    public let id: Int
    public let name: String
    public let originalName: String?
    public let firstAirDate: String?
    public let posterPath: String?
    public let backdropPath: String?
    public let voteAverage: Double?
    public let voteCount: Int?
    public let popularity: Double?
    public let overview: String?
    public let genreIds: [Int]?
    public let character: String?
    public let department: String?
    public let job: String?
}

public struct TMDBPage<Item: Codable & Sendable>: Codable, Sendable {
    public let page: Int?
    public let results: [Item]
    public let totalPages: Int?
}

public struct TMDBCredits: Codable, Sendable, Equatable, Hashable {
    public let cast: [TMDBPerson]
    public let crew: [TMDBPerson]?
}

public struct TMDBPersonCredits<Item: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public let cast: [Item]
    public let crew: [Item]?
}

public struct TMDBVideo: Codable, Sendable, Equatable, Hashable {
    public let key: String
    public let site: String?
    public let type: String?
    public let official: Bool?
    public let name: String?
}

public struct TMDBVideos: Codable, Sendable { public let results: [TMDBVideo] }

public struct TMDBDetails: Codable, Sendable, Equatable, Hashable {
    public struct Country: Codable, Sendable, Equatable, Hashable { public let iso31661: String? }
    public let id: Int
    public let title: String?
    public let name: String?
    public let productionCountries: [Country]?
    public let originCountry: [String]?
    public let createdBy: [TMDBPerson]?
    public let runtime: Int?
    public let posterPath: String?
    public let backdropPath: String?
    public let overview: String?
    public let genres: [Genre]?
    public let voteAverage: Double?
    public let voteCount: Int?
    public struct Genre: Codable, Sendable, Equatable, Hashable { public let id: Int; public let name: String }

    /// Production countries first for movies, origin country first for series.
    public func countryCodes(preferOrigin: Bool) -> [String] {
        let production = (productionCountries ?? []).compactMap(\.iso31661)
        let origin = originCountry ?? []
        return (preferOrigin ? [origin, production] : [production, origin]).first { !$0.isEmpty } ?? []
    }
}

public struct TMDBExternalIDs: Codable, Sendable, Equatable, Hashable {
    public let id: Int?
    public let imdbId: String?
    public let tvdbId: Int?
}

public struct TMDBFind: Codable, Sendable, Equatable, Hashable {
    public struct TV: Codable, Sendable, Equatable, Hashable { public let id: Int }
    public struct Movie: Codable, Sendable, Equatable, Hashable { public let id: Int }
    public let tvResults: [TV]
    public let movieResults: [Movie]?
}

public struct TMDBConfiguration: Codable, Sendable, Equatable, Hashable {
    public struct Images: Codable, Sendable, Equatable, Hashable { public let secureBaseUrl: String? }
    public let images: Images?
}
