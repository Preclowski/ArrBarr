import Foundation
import ArrCore

/// Full title detail, fetched in one round trip via `append_to_response`.
public struct TitleDetails: Sendable {
    public let item: MediaItem
    public let tagline: String?
    public let overview: String?
    public let genres: [String]
    public let runtimeMinutes: Int?          // movies
    public let seasonCount: Int?             // TV
    public let episodeCount: Int?            // TV
    /// TV only: every season the show has, specials last.
    public let seasons: [SeasonSummary]
    public let status: String?
    public let releaseDate: String?
    public let rating: Double?
    public let voteCount: Int?
    public let imdbId: String?
    public let trailerYouTubeKey: String?
    /// Every YouTube clip TMDB has for the title, best first — trailers
    /// before teasers before the rest. A big release usually has several,
    /// and one of them is the one the user wanted.
    public let videos: [Video]
    public let cast: [CastMember]
    public let directors: [PersonCredit]
    public let creators: [PersonCredit]
    public let recommendations: [MediaItem]
    public let reviews: [Review]
    public let streamingProviders: [Brand]
    /// TMDB's "where to watch" page for the configured region — the only
    /// per-title watch link the API gives, and the same one their site uses.
    public let streamingLink: URL?
    /// Who produced it. Deliberately NOT the network: TMDB answers "network"
    /// with whichever station aired the thing, which says nothing about the
    /// title. The production company does.
    public let studios: [Brand]
    /// Where it was made, as ISO 3166-1 codes — TMDB's production countries,
    /// or a show's origin country when it lists no producer. Codes rather
    /// than TMDB's English names: the hero shows them in the app's language.
    public let countryCodes: [String]
    /// The title drawn in its own lettering, when TMDB has one. Same artwork
    /// Plex's agents download — the hero prefers the media server's copy and
    /// falls back to this.
    public let logoPath: String?

    public var logoURL: URL? { TMDBClient.imageURL(path: logoPath, size: "w500") }
    /// Public TMDB lists featuring this title (movies only — TMDB has no
    /// per-title list endpoint for TV).
    public let tmdbLists: [TMDBListRef]

    /// A brand with a mark of its own — a streaming service, a studio. TMDB
    /// ships the logo, which is why these are not plain strings: a hero says
    /// "Netflix" better in Netflix's own letters than in ours.
    public struct Brand: Identifiable, Sendable, Hashable {
        public let id: Int
        public let name: String
        public let logoPath: String?

        public var logoURL: URL? { TMDBClient.imageURL(path: logoPath, size: "w185") }

        /// The house behind the service name: "Apple TV", "Apple TV+" and
        /// "Apple TV Plus" are all Apple; "Prime Video" is Amazon.
        var family: String {
            let first = name.lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "." }).first.map(String.init) ?? name
            switch first {
            case "prime": return "amazon"
            case "max": return "hbo"
            default: return first
            }
        }
    }

    /// A named crew credit. Carries the TMDB person id so the hero's
    /// "Director: …" line can push straight to the person page.
    public struct PersonCredit: Identifiable, Sendable, Hashable {
        public let id: Int
        public let name: String
    }

    /// One season as the show payload knows it — enough for the picker;
    /// the episodes themselves are fetched per season on demand.
    public struct SeasonSummary: Identifiable, Sendable, Hashable {
        public let id: Int
        public let seasonNumber: Int
        public let name: String
        public let overview: String?
        public let episodeCount: Int
        public let airDate: String?
        public let posterPath: String?
        public let rating: Double?

        public var posterURL: URL? { TMDBClient.imageURL(path: posterPath, size: "w342") }
        public var year: Int? {
            (airDate?.count ?? 0) >= 4 ? Int(airDate!.prefix(4)) : nil
        }
    }

    public struct CastMember: Identifiable, Sendable, Hashable {
        public let id: Int
        public let name: String
        public let character: String?
        public let profilePath: String?
        public var photoURL: URL? { TMDBClient.imageURL(path: profilePath, size: "w185") }
    }

    /// One YouTube clip: what it is called, what kind it is, and the still
    /// YouTube itself serves for it.
    public struct Video: Identifiable, Sendable, Hashable {
        public let id: String        // the YouTube key
        public let name: String
        public let kind: String?     // "Trailer", "Teaser", "Clip", …

        public var thumbnailURL: URL? {
            URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")
        }
    }

    public struct Review: Identifiable, Sendable, Hashable {
        public let id: String
        public let author: String
        public let content: String
        public let rating: Double?
    }

    /// The countries in the reader's language ("Stany Zjednoczone", not
    /// "United States"), at most two — a co-production of six is a fact for
    /// the credits, not for a hero.
    public var countryNames: [String] {
        countryCodes.prefix(2).compactMap {
            Locale.current.localizedString(forRegionCode: $0) ?? ($0.isEmpty ? nil : $0)
        }
    }

    public var tmdbURL: URL? {
        URL(string: "https://www.themoviedb.org/\(item.type.rawValue)/\(item.tmdbId)")
    }
    public var imdbURL: URL? {
        imdbId.flatMap { URL(string: "https://www.imdb.com/title/\($0)/") }
    }
}

struct RawDetails: Decodable {
    struct Genre: Decodable { let name: String }
    struct Videos: Decodable { let results: [RawVideo] }
    struct RawVideo: Decodable {
        let key: String
        let site: String?
        let type: String?
        let official: Bool?
        let name: String?
    }
    struct Credits: Decodable {
        let cast: [RawPerson]?
        let crew: [RawPerson]?
    }
    struct RawPerson: Decodable {
        let id: Int
        let name: String
        let character: String?
        let job: String?
        let profilePath: String?
        enum CodingKeys: String, CodingKey {
            case id, name, character, job
            case profilePath = "profile_path"
        }
    }
    struct Reviews: Decodable { let results: [RawReview]? }
    struct RawReview: Decodable {
        let id: String
        let author: String
        let content: String
        let authorDetails: AuthorDetails?
        enum CodingKeys: String, CodingKey {
            case id, author, content
            case authorDetails = "author_details"
        }
        struct AuthorDetails: Decodable { let rating: Double? }
    }
    struct WatchProviders: Decodable { let results: [String: RegionProviders]? }
    struct RegionProviders: Decodable {
        let flatrate: [Provider]?
        let link: String?
        struct Provider: Decodable {
            let providerId: Int?
            let providerName: String?
            let logoPath: String?
            enum CodingKeys: String, CodingKey {
                case providerId = "provider_id"
                case providerName = "provider_name"
                case logoPath = "logo_path"
            }
        }
    }
    struct Creator: Decodable { let id: Int; let name: String }
    struct RawCountry: Decodable {
        let iso3166: String?
        enum CodingKeys: String, CodingKey { case iso3166 = "iso_3166_1" }
    }
    struct Images: Decodable {
        let logos: [Logo]?
        struct Logo: Decodable {
            let filePath: String?
            let iso639: String?
            let voteAverage: Double?
            enum CodingKeys: String, CodingKey {
                case filePath = "file_path"
                case iso639 = "iso_639_1"
                case voteAverage = "vote_average"
            }
        }
    }
    struct RawCompany: Decodable {
        let id: Int
        let name: String
        let logoPath: String?
        enum CodingKeys: String, CodingKey {
            case id, name
            case logoPath = "logo_path"
        }
    }
    struct RawSeason: Decodable {
        let id: Int
        let name: String?
        let overview: String?
        let seasonNumber: Int?
        let episodeCount: Int?
        let airDate: String?
        let posterPath: String?
        let voteAverage: Double?
        enum CodingKeys: String, CodingKey {
            case id, name, overview
            case seasonNumber = "season_number"
            case episodeCount = "episode_count"
            case airDate = "air_date"
            case posterPath = "poster_path"
            case voteAverage = "vote_average"
        }
    }
    struct Lists: Decodable { let results: [RawList]? }
    struct RawList: Decodable {
        let id: Int
        let name: String
        let itemCount: Int?
        enum CodingKeys: String, CodingKey {
            case id, name
            case itemCount = "item_count"
        }
    }

    let id: Int
    let title: String?
    let name: String?
    let tagline: String?
    let overview: String?
    let genres: [Genre]?
    let runtime: Int?
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?
    let status: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    let imdbId: String?
    let backdropPath: String?
    let posterPath: String?
    let videos: Videos?
    let credits: Credits?
    let recommendations: TMDBService.Page?
    let reviews: Reviews?
    let watchProviders: WatchProviders?
    let createdBy: [Creator]?
    let productionCompanies: [RawCompany]?
    let productionCountries: [RawCountry]?
    /// TV only, and the fallback: a show with no production company still
    /// says where it aired from.
    let originCountry: [String]?
    let images: Images?
    let seasons: [RawSeason]?
    let lists: Lists?

    enum CodingKeys: String, CodingKey {
        case id, title, name, tagline, overview, genres, runtime, status, videos, credits, recommendations, reviews, lists, seasons
        case numberOfSeasons = "number_of_seasons"
        case numberOfEpisodes = "number_of_episodes"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case imdbId = "imdb_id"
        case backdropPath = "backdrop_path"
        case posterPath = "poster_path"
        case watchProviders = "watch/providers"
        case createdBy = "created_by"
        case productionCompanies = "production_companies"
        case productionCountries = "production_countries"
        case originCountry = "origin_country"
        case images
    }
}

extension TitleDetails {
    init(raw: RawDetails, base: MediaItem, region: String) {
        let date = base.type == .movie ? raw.releaseDate : raw.firstAirDate
        let year = (date?.count ?? 0) >= 4 ? Int(date!.prefix(4)) : base.year
        let item = MediaItem(
            tmdbId: raw.id, type: base.type,
            title: (base.type == .movie ? raw.title : raw.name) ?? base.title,
            year: year,
            posterPath: raw.posterPath ?? base.posterPath,
            backdropPath: raw.backdropPath ?? base.backdropPath,
            rating: raw.voteAverage ?? base.rating,
            voteCount: raw.voteCount ?? base.voteCount,
            overview: raw.overview ?? base.overview
        )

        // Reuse ArrCore's trailer ranking (official trailer > teaser > rest).
        let videos = (raw.videos?.results ?? []).map {
            TMDBVideo(key: $0.key, site: $0.site, type: $0.type, official: $0.official, name: $0.name)
        }

        let crew = raw.credits?.crew ?? []

        // YouTube only (TMDB also lists Vimeo now and then), official first,
        // trailers before teasers before clips — the order a viewer expects
        // the row to be in.
        let kindRank = { (kind: String?) in
            switch kind {
            case "Trailer": 0
            case "Teaser": 1
            case "Clip": 2
            default: 3
            }
        }
        let clips: [Video] = (raw.videos?.results ?? [])
            .filter { ($0.site ?? "YouTube") == "YouTube" }
            .sorted { lhs, rhs in
                if kindRank(lhs.type) != kindRank(rhs.type) {
                    return kindRank(lhs.type) < kindRank(rhs.type)
                }
                return (lhs.official ?? false) && !(rhs.official ?? false)
            }
            .prefix(12)
            .map { Video(id: $0.key, name: $0.name ?? "", kind: $0.type) }

        let watch = raw.watchProviders?.results?[region]
        let providers: [Brand] = (watch?.flatrate ?? [])
            .compactMap { provider -> Brand? in
                guard let name = provider.providerName else { return nil }
                return Brand(id: provider.providerId ?? name.hashValue,
                             name: name, logoPath: provider.logoPath)
            }
            // One mark per house: TMDB lists "Apple TV" and "Apple TV+" as two
            // providers, and two near-identical apples in a row read as a bug
            // rather than as a choice.
            .reduce(into: [Brand]()) { seen, brand in
                if !seen.contains(where: { $0.family == brand.family }) { seen.append(brand) }
            }
            .prefix(4)
            .map { $0 }

        let countries: [String] = {
            let produced = (raw.productionCountries ?? []).compactMap(\.iso3166)
            return produced.isEmpty ? (raw.originCountry ?? []) : produced
        }()

        let studios: [Brand] = (raw.productionCompanies ?? [])
            .prefix(2)
            .map { Brand(id: $0.id, name: $0.name, logoPath: $0.logoPath) }

        // English first, then the language-neutral marks; PNG only, since
        // TMDB's SVG logos are not what `NSImage` reads reliably.
        let logoRank = { (code: String?) in code == "en" ? 0 : (code == nil ? 1 : 2) }
        let logoPath: String? = (raw.images?.logos ?? [])
            .filter { ($0.filePath ?? "").hasSuffix(".png") }
            .sorted { lhs, rhs in
                logoRank(lhs.iso639) == logoRank(rhs.iso639)
                    ? (lhs.voteAverage ?? 0) > (rhs.voteAverage ?? 0)
                    : logoRank(lhs.iso639) < logoRank(rhs.iso639)
            }
            .first?.filePath

        let seasons: [SeasonSummary] = (raw.seasons ?? [])
            .compactMap { season -> SeasonSummary? in
                guard let number = season.seasonNumber else { return nil }
                return SeasonSummary(
                    id: season.id,
                    seasonNumber: number,
                    name: season.name ?? String(
                        format: String(localized: "Season %d", bundle: .module), number),
                    overview: season.overview?.isEmpty == true ? nil : season.overview,
                    episodeCount: season.episodeCount ?? 0,
                    airDate: season.airDate,
                    posterPath: season.posterPath,
                    rating: (season.voteAverage ?? 0) > 0 ? season.voteAverage : nil)
            }
            // Specials (season 0) belong after the real run, the way every
            // show page orders them.
            .sorted {
                ($0.seasonNumber == 0 ? Int.max : $0.seasonNumber)
                    < ($1.seasonNumber == 0 ? Int.max : $1.seasonNumber)
            }

        self.init(
            item: item,
            tagline: raw.tagline?.isEmpty == true ? nil : raw.tagline,
            overview: raw.overview,
            genres: (raw.genres ?? []).map(\.name),
            runtimeMinutes: raw.runtime,
            seasonCount: raw.numberOfSeasons,
            episodeCount: raw.numberOfEpisodes,
            seasons: seasons,
            status: raw.status,
            releaseDate: date,
            rating: raw.voteAverage,
            voteCount: raw.voteCount,
            imdbId: raw.imdbId,
            trailerYouTubeKey: TMDBVideo.bestTrailerKey(videos),
            videos: clips,
            cast: (raw.credits?.cast ?? []).prefix(20).map {
                CastMember(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profilePath)
            },
            directors: crew.filter { $0.job == "Director" }
                .map { PersonCredit(id: $0.id, name: $0.name) },
            creators: (raw.createdBy ?? []).map { PersonCredit(id: $0.id, name: $0.name) },
            recommendations: (raw.recommendations?.results ?? [])
                .compactMap { $0.item(defaultType: base.type) },
            reviews: (raw.reviews?.results ?? []).prefix(6).map {
                Review(id: $0.id, author: $0.author, content: $0.content, rating: $0.authorDetails?.rating)
            },
            streamingProviders: providers,
            streamingLink: watch?.link.flatMap { URL(string: $0) },
            studios: studios,
            countryCodes: countries,
            logoPath: logoPath,
            tmdbLists: (raw.lists?.results ?? [])
                .filter { ($0.itemCount ?? 0) >= 4 }
                .prefix(12)
                .map { TMDBListRef(id: $0.id, name: $0.name, itemCount: $0.itemCount ?? 0) }
        )
    }
}

/// A public TMDB list a title appears in — navigable from the detail page.
public struct TMDBListRef: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let itemCount: Int
}
