import Foundation

/// What kind of thing an id names. Part of every identity because ids are only
/// unique per namespace *and* per kind — TMDB movie 603 and TMDB series 603
/// are different titles, and that confusion is how a link opens the wrong
/// thing.
public enum MediaKind: String, Hashable, Sendable, Codable, CaseIterable {
    case movie
    case series
    case season
    case episode
    /// Lidarr's world. TonightBarr shows neither, but ArrBarr browses both and
    /// the model has to hold them or it will be forked the day it moves.
    case artist
    case album
}

/// Which media server a server-local id came from. Their id spaces are
/// private to the server, so the kind travels with the id.
public enum MediaServerFlavor: String, Hashable, Sendable, Codable {
    case plex
    case jellyfin
    case emby
}

/// Which arr a numeric library id came from. Same reasoning: Radarr movie 12
/// and Sonarr series 12 share nothing but the number.
public enum ArrFlavor: String, Hashable, Sendable, Codable {
    case radarr
    case sonarr
    case lidarr
    case whisparr
}

/// One id, in one namespace.
///
/// Kept as an enum rather than a bare `Int`/`String` so a value carries the
/// scheme it belongs to. The distinction between `.tmdbMovie` and `.tmdbSeries`
/// is deliberate and load-bearing: TMDB has two id spaces, no arr can resolve
/// a TMDB series id directly, and treating them as one number is the classic
/// way to open the wrong title.
public enum MediaID: Hashable, Sendable, Codable {
    case tmdbMovie(Int)
    case tmdbSeries(Int)
    case tvdb(Int)
    /// "ttNNNNNNN" — stored verbatim, prefix included, because that is how
    /// every service writes it.
    case imdb(String)
    case musicBrainz(String)
    /// A media server's own item id (Plex ratingKey/guid, Jellyfin item id).
    case server(MediaServerFlavor, String)
    /// An arr's library row id.
    case arr(ArrFlavor, Int)

    /// The namespace, without the value — used for "do I already know an id
    /// of this kind?" lookups and as the debug label.
    public var namespace: Namespace {
        switch self {
        case .tmdbMovie: .tmdbMovie
        case .tmdbSeries: .tmdbSeries
        case .tvdb: .tvdb
        case .imdb: .imdb
        case .musicBrainz: .musicBrainz
        case .server(let flavor, _): .server(flavor)
        case .arr(let flavor, _): .arr(flavor)
        }
    }

    public enum Namespace: Hashable, Sendable {
        case tmdbMovie, tmdbSeries, tvdb, imdb, musicBrainz
        case server(MediaServerFlavor)
        case arr(ArrFlavor)
    }

    /// The kind this id can only ever name, when the namespace settles it.
    /// `nil` where the namespace spans kinds (IMDb ids name films and series
    /// alike, an arr id follows its arr).
    public var impliedKind: MediaKind? {
        switch self {
        case .tmdbMovie: .movie
        case .tmdbSeries, .tvdb: .series
        case .arr(let flavor, _): flavor == .sonarr ? .series : .movie
        case .imdb, .musicBrainz, .server: nil
        }
    }

    /// Stable, human-readable form — cache keys, logs, deep links.
    /// Round-trips through `init?(token:)`.
    public var token: String {
        switch self {
        case .tmdbMovie(let id): "tmdb-movie:\(id)"
        case .tmdbSeries(let id): "tmdb-series:\(id)"
        case .tvdb(let id): "tvdb:\(id)"
        case .imdb(let id): "imdb:\(id)"
        case .musicBrainz(let id): "mbid:\(id)"
        case .server(let flavor, let id): "\(flavor.rawValue):\(id)"
        case .arr(let flavor, let id): "\(flavor.rawValue):\(id)"
        }
    }

    public init?(token: String) {
        guard let separator = token.firstIndex(of: ":") else { return nil }
        let scheme = String(token[token.startIndex..<separator])
        let value = String(token[token.index(after: separator)...])
        guard !value.isEmpty else { return nil }
        switch scheme {
        case "tmdb-movie": guard let id = Int(value) else { return nil }; self = .tmdbMovie(id)
        case "tmdb-series": guard let id = Int(value) else { return nil }; self = .tmdbSeries(id)
        case "tvdb": guard let id = Int(value) else { return nil }; self = .tvdb(id)
        case "imdb": self = .imdb(value)
        case "mbid": self = .musicBrainz(value)
        default:
            if let flavor = MediaServerFlavor(rawValue: scheme) {
                self = .server(flavor, value)
            } else if let flavor = ArrFlavor(rawValue: scheme), let id = Int(value) {
                self = .arr(flavor, id)
            } else {
                return nil
            }
        }
    }
}
