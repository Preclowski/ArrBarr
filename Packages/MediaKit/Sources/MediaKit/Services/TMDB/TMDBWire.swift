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
    /// TV `aggregate_credits`: the characters played, one per stint.
    public let roles: [Role]?

    public struct Role: Codable, Sendable, Equatable, Hashable { public let character: String?; public let episodeCount: Int? }
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

/// `/tv/{id}/season/{n}/episode/{n}` — only what a rating needs.
public struct TMDBEpisode: Codable, Sendable, Equatable, Hashable {
    public let id: Int?
    public let voteAverage: Double?
    public let voteCount: Int?
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
    public let originalTitle: String?
    public let originalName: String?
    public let tagline: String?
    public let status: String?
    public let imdbId: String?
    public let budget: Int?
    public let revenue: Int?
    public let numberOfSeasons: Int?
    public let numberOfEpisodes: Int?
    public let lastEpisodeToAir: Airing?
    public let nextEpisodeToAir: Airing?
    public let seasons: [Airing]?
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
    /// An episode or a season: when it aired and which season it belongs to.
    public struct Airing: Codable, Sendable, Equatable, Hashable { public let airDate: String?; public let seasonNumber: Int? }

    /// Production countries first for movies, origin country first for series; uppercased, without repeats.
    public func countryCodes(preferOrigin: Bool) -> [String] {
        let production = (productionCountries ?? []).compactMap(\.iso31661)
        let origin = originCountry ?? []
        let picked = (preferOrigin ? [origin, production] : [production, origin]).first { !$0.isEmpty } ?? []
        var seen = Set<String>()
        return picked.map { $0.uppercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
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
