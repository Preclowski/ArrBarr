import Foundation
import ArrCore

/// One season with its episodes. Fetched per season on demand — the show
/// payload only carries season summaries, and pulling every episode of a
/// long-running series up front would be megabytes for a page nobody
/// scrolled to yet.
public struct SeasonDetails: Sendable {
    public let showId: Int
    public let seasonNumber: Int
    public let name: String
    public let overview: String?
    public let airDate: String?
    public let posterPath: String?
    public let episodes: [Episode]

    public var posterURL: URL? { TMDBClient.imageURL(path: posterPath, size: "w342") }

    public struct Episode: Identifiable, Sendable, Hashable {
        public let id: Int
        public let episodeNumber: Int
        public let seasonNumber: Int
        public let name: String
        public let overview: String?
        public let airDate: String?
        public let runtimeMinutes: Int?
        public let stillPath: String?
        public let rating: Double?
        public let voteCount: Int?

        /// 16:9 frame grab. `w300` is the smallest still TMDB ships and is
        /// plenty for an episode row.
        public var stillURL: URL? { TMDBClient.imageURL(path: stillPath, size: "w300") }

        /// "S01E04" — the way everyone writes an episode down.
        public var code: String {
            String(format: "S%02dE%02d", seasonNumber, episodeNumber)
        }

        public var airDateValue: Date? {
            airDate.flatMap { SeasonDetails.dateFormatter.date(from: $0) }
        }
        /// An episode TMDB knows about but that hasn't aired yet.
        public var isUpcoming: Bool {
            guard let date = airDateValue else { return false }
            return date > Date()
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

extension TMDBService {
    /// Episodes of one season of one show.
    public func season(showId: Int, seasonNumber: Int) async throws -> SeasonDetails {
        struct RawSeason: Decodable {
            struct RawEpisode: Decodable {
                let id: Int
                let name: String?
                let overview: String?
                let episodeNumber: Int?
                let seasonNumber: Int?
                let airDate: String?
                let runtime: Int?
                let stillPath: String?
                let voteAverage: Double?
                let voteCount: Int?
                enum CodingKeys: String, CodingKey {
                    case id, name, overview, runtime
                    case episodeNumber = "episode_number"
                    case seasonNumber = "season_number"
                    case airDate = "air_date"
                    case stillPath = "still_path"
                    case voteAverage = "vote_average"
                    case voteCount = "vote_count"
                }
            }
            let name: String?
            let overview: String?
            let airDate: String?
            let posterPath: String?
            let seasonNumber: Int?
            let episodes: [RawEpisode]?
            enum CodingKeys: String, CodingKey {
                case name, overview, episodes
                case airDate = "air_date"
                case posterPath = "poster_path"
                case seasonNumber = "season_number"
            }
        }

        let raw: RawSeason = try await get(
            path: "/tv/\(showId)/season/\(seasonNumber)", query: [])
        return SeasonDetails(
            showId: showId,
            seasonNumber: raw.seasonNumber ?? seasonNumber,
            name: raw.name ?? String(
                format: String(localized: "Season %d", bundle: .module), seasonNumber),
            overview: raw.overview?.isEmpty == true ? nil : raw.overview,
            airDate: raw.airDate,
            posterPath: raw.posterPath,
            episodes: (raw.episodes ?? []).map { episode in
                SeasonDetails.Episode(
                    id: episode.id,
                    episodeNumber: episode.episodeNumber ?? 0,
                    seasonNumber: episode.seasonNumber ?? seasonNumber,
                    name: episode.name ?? "",
                    overview: episode.overview?.isEmpty == true ? nil : episode.overview,
                    airDate: episode.airDate,
                    runtimeMinutes: (episode.runtime ?? 0) > 0 ? episode.runtime : nil,
                    stillPath: episode.stillPath,
                    rating: (episode.voteAverage ?? 0) > 0 ? episode.voteAverage : nil,
                    voteCount: episode.voteCount)
            }
            .sorted { $0.episodeNumber < $1.episodeNumber })
    }
}
