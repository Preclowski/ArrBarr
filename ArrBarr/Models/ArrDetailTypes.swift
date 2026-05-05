import Foundation

// MARK: - Radarr movie detail

struct RadarrMovieDetail: Decodable {
    let id: Int
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

struct RadarrDetailRatings: Decodable {
    let imdb: RadarrRatingValue?
    let tmdb: RadarrRatingValue?
    let metacritic: RadarrRatingValue?
    let rottenTomatoes: RadarrRatingValue?
}

struct RadarrRatingValue: Decodable {
    let value: Double?
    let votes: Int?
}

// MARK: - Sonarr series detail

struct SonarrSeriesDetail: Decodable {
    let id: Int
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

struct SonarrDetailRatings: Decodable {
    let value: Double?
    let votes: Int?
}

struct SonarrSeasonInfo: Decodable {
    let seasonNumber: Int
    let monitored: Bool?
    let statistics: SonarrSeasonStats?
}

struct SonarrSeasonStats: Decodable {
    let episodeFileCount: Int?
    let episodeCount: Int?
    let totalEpisodeCount: Int?
    let sizeOnDisk: Int64?
    let percentOfEpisodes: Double?
}

struct SonarrEpisodeDetail: Decodable, Identifiable {
    let id: Int
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

struct LidarrAlbumDetail: Decodable {
    let id: Int
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

struct LidarrDetailRatings: Decodable {
    let value: Double?
    let votes: Int?
}

struct LidarrAlbumStats: Decodable {
    let trackCount: Int?
    let trackFileCount: Int?
    let totalTrackCount: Int?
    let sizeOnDisk: Int64?
}

struct LidarrTrackDetail: Decodable, Identifiable {
    let id: Int
    let trackNumber: String?
    let absoluteTrackNumber: Int?
    let title: String?
    let duration: Int?
    let mediumNumber: Int?
    let hasFile: Bool?
}
