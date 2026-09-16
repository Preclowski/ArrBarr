import Foundation

public enum MediaKind: String, Sendable, Codable, CaseIterable, Hashable {
    case movie, series, season, episode, artist, album, track, person
}

public enum IDNamespace: Hashable, Sendable, Codable {
    case tmdbMovie, tmdbSeries, tmdbPerson
    case tvdb, imdb
    case musicBrainzArtist, musicBrainzAlbum, musicBrainzTrack
    case arr(InstanceID)
    case mediaServer(InstanceID)

    public var impliedKind: MediaKind? {
        switch self {
        case .tmdbMovie: .movie
        case .tmdbSeries, .tvdb: .series
        case .tmdbPerson: .person
        case .musicBrainzArtist: .artist
        case .musicBrainzAlbum: .album
        case .musicBrainzTrack: .track
        case .imdb, .arr, .mediaServer: nil
        }
    }

    var token: String {
        switch self {
        case .tmdbMovie: "tmdb-movie"
        case .tmdbSeries: "tmdb-series"
        case .tmdbPerson: "tmdb-person"
        case .tvdb: "tvdb"
        case .imdb: "imdb"
        case .musicBrainzArtist: "mb-artist"
        case .musicBrainzAlbum: "mb-album"
        case .musicBrainzTrack: "mb-track"
        case let .arr(i): "arr:\(i)"
        case let .mediaServer(i): "server:\(i)"
        }
    }

    init?(token: String) {
        switch token {
        case "tmdb-movie": self = .tmdbMovie
        case "tmdb-series": self = .tmdbSeries
        case "tmdb-person": self = .tmdbPerson
        case "tvdb": self = .tvdb
        case "imdb": self = .imdb
        case "mb-artist": self = .musicBrainzArtist
        case "mb-album": self = .musicBrainzAlbum
        case "mb-track": self = .musicBrainzTrack
        default:
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = InstanceID(token: parts[1]) else { return nil }
            switch parts[0] {
            case "arr": self = .arr(id)
            case "server": self = .mediaServer(id)
            default: return nil
            }
        }
    }
}

extension InstanceID {
    init?(token: String) {
        let parts = token.split(separator: "#").map(String.init)
        guard parts.count == 2, let kind = InstanceKind(rawValue: parts[0]), let ordinal = Int(parts[1]) else { return nil }
        self.init(kind, ordinal: ordinal)
    }
}

public struct MediaID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let namespace: IDNamespace
    public let value: String

    public init(namespace: IDNamespace, value: String) { self.namespace = namespace; self.value = value }

    /// Round-trips `description`: the last `:` separates namespace and value.
    public init?(_ token: String) {
        guard let split = token.lastIndex(of: ":") else { return nil }
        guard let ns = IDNamespace(token: String(token[..<split])) else { return nil }
        let value = String(token[token.index(after: split)...])
        guard !value.isEmpty else { return nil }
        self.init(namespace: ns, value: value)
    }

    public var description: String { "\(namespace.token):\(value)" }

    public static func tmdbMovie(_ id: Int) -> MediaID { .init(namespace: .tmdbMovie, value: String(id)) }
    public static func tmdbSeries(_ id: Int) -> MediaID { .init(namespace: .tmdbSeries, value: String(id)) }
    public static func tmdbPerson(_ id: Int) -> MediaID { .init(namespace: .tmdbPerson, value: String(id)) }
    public static func tvdb(_ id: Int) -> MediaID { .init(namespace: .tvdb, value: String(id)) }
    public static func imdb(_ id: String) -> MediaID { .init(namespace: .imdb, value: id.lowercased()) }
    public static func musicBrainz(_ ns: IDNamespace, _ id: String) -> MediaID { .init(namespace: ns, value: id.lowercased()) }
    public static func arr(_ instance: InstanceID, _ id: Int) -> MediaID { .init(namespace: .arr(instance), value: String(id)) }
    public static func server(_ instance: InstanceID, _ id: String) -> MediaID { .init(namespace: .mediaServer(instance), value: id) }

    public var intValue: Int? { Int(value) }
}

/// One model for every kind; flat lineage keeps it Hashable and Codable.
public struct MediaIdentity: Hashable, Sendable, Codable {
    public struct Ancestor: Hashable, Sendable, Codable {
        public let kind: MediaKind
        public let ids: Set<MediaID>
        public let ordinal: Int?
        public init(kind: MediaKind, ids: Set<MediaID>, ordinal: Int? = nil) { self.kind = kind; self.ids = ids; self.ordinal = ordinal }
    }

    public let kind: MediaKind
    public let ids: Set<MediaID>
    public let ordinal: Int?
    public let lineage: [Ancestor]

    public init(kind: MediaKind, ids: Set<MediaID>, ordinal: Int? = nil, lineage: [Ancestor] = []) {
        self.kind = kind; self.ids = ids; self.ordinal = ordinal; self.lineage = lineage
    }

    public func id(in namespace: IDNamespace) -> MediaID? { ids.first { $0.namespace == namespace } }

    public func merging(_ other: MediaIdentity) -> MediaIdentity {
        MediaIdentity(kind: kind, ids: ids.union(other.ids), ordinal: ordinal ?? other.ordinal, lineage: lineage.isEmpty ? other.lineage : lineage)
    }

    /// Shared id, same kind, same ordinal; never a title or a year.
    public func matches(_ other: MediaIdentity) -> Bool {
        kind == other.kind && ordinal == other.ordinal && !ids.isDisjoint(with: other.ids)
    }
}

public struct Crosswalk: Hashable, Sendable, Codable {
    public enum Confidence: Int, Sendable, Codable, Comparable {
        case inferred = 40, verified = 80, asserted = 100
        public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    }
    public enum Source: String, Sendable, Codable { case arrRecord, arrLookup, mediaServerGuid, tmdbExternalIDs, tmdbFind, libraryIndex }

    public let from: MediaID
    public let to: MediaID
    public let kind: MediaKind
    public let confidence: Confidence
    public let source: Source
    public let fetchedAt: Date

    public init(from: MediaID, to: MediaID, kind: MediaKind, confidence: Confidence, source: Source, fetchedAt: Date) {
        self.from = from; self.to = to; self.kind = kind; self.confidence = confidence; self.source = source; self.fetchedAt = fetchedAt
    }

    public var reversed: Crosswalk { Crosswalk(from: to, to: from, kind: kind, confidence: confidence, source: source, fetchedAt: fetchedAt) }
}
