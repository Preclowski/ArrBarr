import Foundation

/// The identity card of a title. Provider-neutral: TMDB, an arr and a media
/// server all fill the same shape, and the merge decides who wins per field.
public struct TitleFacts: Hashable, Sendable, Codable {
    public var title: String
    public var originalTitle: String?
    public var year: Int?
    public var overview: String?
    public var runtimeMinutes: Int?
    public var genres: [String]
    public var seasonCount: Int?
    public var episodeCount: Int?

    public init(title: String, originalTitle: String? = nil, year: Int? = nil,
                overview: String? = nil, runtimeMinutes: Int? = nil,
                genres: [String] = [], seasonCount: Int? = nil,
                episodeCount: Int? = nil) {
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.overview = overview
        self.runtimeMinutes = runtimeMinutes
        self.genres = genres
        self.seasonCount = seasonCount
        self.episodeCount = episodeCount
    }
}

/// Artwork as references, never as bytes. Who downloads and caches the pixels
/// is a separate concern (and on macOS, `URLCache` already does it well).
public struct Artwork: Hashable, Sendable, Codable {
    public var poster: URL?
    public var backdrop: URL?
    public var logo: URL?

    public init(poster: URL? = nil, backdrop: URL? = nil, logo: URL? = nil) {
        self.poster = poster
        self.backdrop = backdrop
        self.logo = logo
    }
}

/// Which service produced a score. There is no service-less score in this
/// layer, the same way there is no service-less rating badge in the UI.
public enum RatingService: String, Hashable, Sendable, Codable, CaseIterable {
    case tmdb, imdb, rottenTomatoes, metacritic, trakt
    /// TheTVDB's own score, which is what Sonarr carries for a series and the
    /// only score anyone has for shows that TMDB barely knows.
    case tvdb
}

public struct ServiceRating: Hashable, Sendable, Codable {
    public let service: RatingService
    /// Normalised to the service's own scale (TMDB/IMDb 0–10, RT/Metacritic
    /// 0–100). Converting them to one scale loses what the user recognises.
    public let value: Double
    public let voteCount: Int?

    public init(service: RatingService, value: Double, voteCount: Int? = nil) {
        self.service = service
        self.value = value
        self.voteCount = voteCount
    }
}

public struct Ratings: Hashable, Sendable, Codable {
    public var scores: [ServiceRating]

    public init(scores: [ServiceRating] = []) { self.scores = scores }

    public func value(for service: RatingService) -> Double? {
        scores.first { $0.service == service }?.value
    }

    /// Union by service, first writer wins — the caller merges in precedence
    /// order, so a provider that answered earlier is the preferred one.
    public func merging(_ other: Ratings) -> Ratings {
        var merged = scores
        for score in other.scores where !merged.contains(where: { $0.service == score.service }) {
            merged.append(score)
        }
        return Ratings(scores: merged)
    }
}

/// The user's own media world: do they have it, have they watched it, where
/// did it come from. This is the field that must never come from the internet.
public struct Availability: Hashable, Sendable, Codable {
    public var owned: Bool
    public var watched: Bool
    /// 0…1 for a partially watched item, when the source reports it.
    public var playProgress: Double?
    public var lastWatched: Date?
    /// Human-readable sources that contributed ("Plex", "Radarr"), for the
    /// UI's "owned via" affordances and for debugging a wrong badge.
    public var sources: [String]
    /// Sources that were asked and said no. "Not in Radarr" is an answer, not
    /// a gap: without it the UI can only ever list the services that said
    /// yes, and cannot tell "nobody knows" from "Plex has it, Radarr does not".
    public var absent: [String]
    /// Sources that hold the actual file, a subset of `sources`. "Radarr
    /// knows about it" and "the file is on disk" are different answers, and
    /// a badge that cannot tell them apart sends you to an empty folder.
    public var downloaded: [String]
    /// Where to go to see it in that source, keyed by the same name: the
    /// item's own page when the source has it, the source's add/search page
    /// when it does not. A badge that names a service and cannot take you
    /// there is a dead end.
    public var links: [String: URL]

    public init(owned: Bool = false, watched: Bool = false,
                playProgress: Double? = nil, lastWatched: Date? = nil,
                sources: [String] = [], absent: [String] = [],
                downloaded: [String] = [], links: [String: URL] = [:]) {
        self.owned = owned
        self.watched = watched
        self.playProgress = playProgress
        self.lastWatched = lastWatched
        self.sources = sources
        self.absent = absent
        self.downloaded = downloaded
        self.links = links
    }

    /// Availability is a union across sources: owned anywhere is owned,
    /// watched anywhere is watched. Nobody's "no" outvotes somebody's "yes".
    public func merging(_ other: Availability) -> Availability {
        Availability(
            owned: owned || other.owned,
            watched: watched || other.watched,
            playProgress: playProgress ?? other.playProgress,
            lastWatched: [lastWatched, other.lastWatched].compactMap { $0 }.max(),
            sources: sources + other.sources.filter { !sources.contains($0) },
            // A yes anywhere clears the no: the same service can be asked
            // twice (an arr and the library index both speak for Plex).
            absent: (absent + other.absent.filter { !absent.contains($0) })
                .filter { !sources.contains($0) && !other.sources.contains($0) },
            downloaded: downloaded + other.downloaded.filter { !downloaded.contains($0) },
            links: links.merging(other.links) { mine, _ in mine })
    }
}

public struct PersonCredit: Hashable, Sendable, Codable, Identifiable {
    public let id: Int
    public let name: String
    /// The character for cast, the job for crew — what they did on this title.
    public let role: String?
    public let profilePath: String?
    public let isCast: Bool

    public init(id: Int, name: String, role: String? = nil,
                profilePath: String? = nil, isCast: Bool = true) {
        self.id = id
        self.name = name
        self.role = role
        self.profilePath = profilePath
        self.isCast = isCast
    }
}

public struct Credits: Hashable, Sendable, Codable {
    public var people: [PersonCredit]

    public init(people: [PersonCredit] = []) { self.people = people }

    public var cast: [PersonCredit] { people.filter(\.isCast) }
    public var crew: [PersonCredit] { people.filter { !$0.isCast } }
}

public struct StreamingAvailability: Hashable, Sendable, Codable {
    /// Region the answer is valid in — a streaming answer without one is a
    /// wrong answer somewhere.
    public var region: String
    public var flatrate: [String]

    public init(region: String, flatrate: [String] = []) {
        self.region = region
        self.flatrate = flatrate
    }
}
