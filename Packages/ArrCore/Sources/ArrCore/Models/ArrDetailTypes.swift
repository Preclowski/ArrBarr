import Foundation

// MARK: - Radarr movie detail

public struct RadarrMovieDetail: Decodable {
    public let id: Int
    let title: String
    let year: Int?
    let overview: String?
    let runtime: Int?
    let genres: [String]?
    let ratings: RadarrDetailRatings?
    let images: [ArrImage]?
    let studio: String?
    let certification: String?
    let titleSlug: String?
    let movieFile: ArrFile?
    let inCinemas: String?
    let status: String?
}

public struct RadarrDetailRatings: Decodable {
    let imdb: RadarrRatingValue?
    let tmdb: RadarrRatingValue?
    let metacritic: RadarrRatingValue?
    let rottenTomatoes: RadarrRatingValue?
}

public struct RadarrRatingValue: Decodable {
    let value: Double?
    let votes: Int?
}

// MARK: - Sonarr series detail

public struct SonarrSeriesDetail: Decodable {
    public let id: Int
    let title: String
    let year: Int?
    let overview: String?
    let genres: [String]?
    let runtime: Int?
    let ratings: SonarrDetailRatings?
    let network: String?
    let status: String?
    let images: [ArrImage]?
    let titleSlug: String?
    let seasons: [SonarrSeasonInfo]?
    let firstAired: String?
}

public struct SonarrDetailRatings: Decodable {
    let value: Double?
    let votes: Int?
}

public struct SonarrSeasonInfo: Decodable {
    let seasonNumber: Int
    let monitored: Bool?
    let statistics: SonarrSeasonStats?
}

public struct SonarrSeasonStats: Decodable {
    let episodeFileCount: Int?
    let episodeCount: Int?
    let totalEpisodeCount: Int?
    let sizeOnDisk: Int64?
    let percentOfEpisodes: Double?
}

public struct SonarrEpisodeDetail: Decodable, Identifiable {
    public let id: Int
    let seasonNumber: Int?
    let episodeNumber: Int?
    let title: String?
    let overview: String?
    let airDateUtc: String?
    let hasFile: Bool?
    let monitored: Bool?
    let runtime: Int?
}

// MARK: - Lidarr album detail

public struct LidarrAlbumDetail: Decodable {
    public let id: Int
    let title: String
    let overview: String?
    let releaseDate: String?
    let genres: [String]?
    let ratings: LidarrDetailRatings?
    let images: [ArrImage]?
    let artist: LidarrArtist?
    let foreignAlbumId: String?
    let albumType: String?
    let duration: Int?
    let statistics: LidarrAlbumStats?
}

public struct LidarrDetailRatings: Decodable {
    let value: Double?
    let votes: Int?
}

public struct LidarrAlbumStats: Decodable {
    let trackCount: Int?
    let trackFileCount: Int?
    let totalTrackCount: Int?
    let sizeOnDisk: Int64?
}

public struct LidarrTrackDetail: Decodable, Identifiable {
    public let id: Int
    let trackNumber: String?
    let absoluteTrackNumber: Int?
    let title: String?
    let duration: Int?
    let mediumNumber: Int?
    let hasFile: Bool?
}
