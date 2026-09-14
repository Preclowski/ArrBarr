import Foundation

/// Everything known about ONE work, across every id space it appears in:
/// "Plex item 8fa3 is Radarr movie 12 is tmdb 603 is tt0068646".
///
/// A single id (ArrCore's `MediaRef`) is enough to *ask* a question; a set is
/// what answering one needs, because merging two providers' answers means
/// deciding whether they are talking about the same title. Providers hand back
/// the ids they learned along the way, and the identity grows.
public struct MediaIdentity: Hashable, Sendable, Codable {
    public let kind: MediaKind
    public private(set) var ids: Set<MediaID>

    public init(kind: MediaKind, ids: Set<MediaID>) {
        self.kind = kind
        self.ids = ids
    }

    /// Identity from one id, taking the kind the namespace implies where it
    /// can — `.tmdbMovie(603)` is unambiguously a movie.
    public init(_ id: MediaID, kind: MediaKind? = nil) {
        self.kind = kind ?? id.impliedKind ?? .movie
        self.ids = [id]
    }

    public static func tmdbMovie(_ id: Int) -> MediaIdentity { .init(.tmdbMovie(id)) }
    public static func tmdbSeries(_ id: Int) -> MediaIdentity { .init(.tmdbSeries(id)) }

    public func id(in namespace: MediaID.Namespace) -> MediaID? {
        ids.first { $0.namespace == namespace }
    }

    public var tmdbID: Int? {
        for id in ids {
            switch id {
            case .tmdbMovie(let value), .tmdbSeries(let value): return value
            default: continue
            }
        }
        return nil
    }

    public var imdbID: String? {
        for case .imdb(let value) in ids { return value }
        return nil
    }

    public func contains(_ id: MediaID) -> Bool { ids.contains(id) }

    /// True when the two identities provably name the same work — they share
    /// at least one id. Deliberately NOT a title/year heuristic: fuzzy title
    /// matching belongs in a resolver that can say how sure it is, not in the
    /// type that everything downstream trusts.
    public func matches(_ other: MediaIdentity) -> Bool {
        kind == other.kind && !ids.isDisjoint(with: other.ids)
    }

    public mutating func insert(_ id: MediaID) {
        ids.insert(id)
    }

    /// Fold another identity's ids in. Returns `false` and changes nothing
    /// when the two are not provably the same work, so a bad merge fails
    /// loudly at the call site instead of quietly inventing a title.
    @discardableResult
    public mutating func merge(_ other: MediaIdentity) -> Bool {
        guard matches(other) else { return false }
        ids.formUnion(other.ids)
        return true
    }

    public func merging(_ other: MediaIdentity) -> MediaIdentity {
        var copy = self
        copy.merge(other)
        return copy
    }

    /// The id a cache keys on: the most portable one this identity carries.
    /// Order matters — a value cached under a server-local id would be lost
    /// the moment the same title is reached through TMDB instead.
    public var canonicalID: MediaID {
        let preference: [MediaID.Namespace] = [
            .tmdbMovie, .tmdbSeries, .tvdb, .imdb, .musicBrainz,
        ]
        for namespace in preference {
            if let id = id(in: namespace) { return id }
        }
        // Every identity has at least one id; the sort keeps the choice
        // stable across runs when only server/arr ids are known.
        return ids.sorted { $0.token < $1.token }.first!
    }

    public var cacheKey: String { "\(kind.rawValue)/\(canonicalID.token)" }
}

extension MediaIdentity: CustomStringConvertible {
    public var description: String {
        "\(kind.rawValue)[\(ids.map(\.token).sorted().joined(separator: " "))]"
    }
}
