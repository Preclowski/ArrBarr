import Foundation

/// Stable cross-system identity for a media item: the id scheme travels with the value.
nonisolated public enum MediaRef: Hashable, Sendable {
    case tmdb(Int)
    case tvdb(Int)
    /// TMDB's series id — a different id space from `.tmdb` (movies); the same number names a different title.
    /// No arr resolves it directly: it goes through `SeriesIdentityResolver` to become `.tvdb` first.
    case tmdbTV(Int)
    case musicBrainz(String)
    case imdb(String)        // "ttNNNNNNN" — verbatim, including prefix

    public var compatibleSources: Set<QueueItem.Source> {
        switch self {
        case .tmdb:        return [.radarr, .whisparr]
        case .tvdb:        return [.sonarr]
        // Deliberately empty: no arr can look up a TMDB series id, so the only route to Sonarr is
        // `SeriesIdentityResolver`, which proves the identity instead of matching a title.
        case .tmdbTV:      return []
        case .musicBrainz: return [.lidarr]
        // Asking a server that doesn't support `imdb:` is harmless: the ranker matches on the record's own `imdbId`.
        case .imdb:        return [.radarr, .sonarr]
        }
    }

    /// Term for the arr's `/lookup?term=`. `musicBrainz` is the bare GUID — Lidarr keys on it without a prefix.
    public var lookupTerm: String {
        switch self {
        case .tmdb(let id):        return "tmdb:\(id)"
        case .tvdb(let id):        return "tvdb:\(id)"
        // Sonarr only: older SkyHook treats this as literal text, so callers must check the record's tmdbId.
        // The same string means a movie to Radarr.
        case .tmdbTV(let id):      return "tmdb:\(id)"
        case .musicBrainz(let id): return id
        case .imdb(let id):        return "imdb:\(id)"
        }
    }

    /// URL form for deep links and chat-tool JSON. Unlike `lookupTerm`, MusicBrainz keeps a scheme so it parses.
    public var urlString: String {
        switch self {
        case .tmdb(let id):        return "tmdb:\(id)"
        case .tvdb(let id):        return "tvdb:\(id)"
        // Its own scheme: a shared "tmdb:" would round-trip a series into an unrelated movie.
        case .tmdbTV(let id):      return "tmdbtv:\(id)"
        case .musicBrainz(let id): return "mb:\(id)"
        case .imdb(let id):        return "imdb:\(id)"
        }
    }

    /// False for an empty id slot (`.tvdb(0)`); such a ref looks like an id and resolves to nothing.
    public var isAddressable: Bool {
        switch self {
        case .tmdb(let id), .tvdb(let id), .tmdbTV(let id): return id > 0
        case .musicBrainz(let id): return !id.isEmpty
        case .imdb(let id):        return id.count > 2
        }
    }

    public init?(urlString: String) {
        let s = urlString.trimmingCharacters(in: .whitespaces)
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let scheme = s[..<colon].lowercased()
        let value = String(s[s.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch scheme {
        case "tmdb":
            guard let n = Int(value) else { return nil }
            self = .tmdb(n)
        case "tvdb":
            guard let n = Int(value) else { return nil }
            self = .tvdb(n)
        case "tmdbtv":
            guard let n = Int(value) else { return nil }
            self = .tmdbTV(n)
        case "mb", "musicbrainz", "lidarr":
            // Lidarr accepts other foreign-id forms at some catalog edges, so don't insist on a 36-char GUID.
            self = .musicBrainz(value)
        case "imdb":
            // Accept a missing "tt" prefix and normalise it.
            let normalised = value.hasPrefix("tt") ? value : "tt\(value)"
            self = .imdb(normalised)
        default:
            return nil
        }
    }
}

// MARK: - SearchResult bridge

nonisolated public extension SearchResult {
    var mediaRef: MediaRef {
        switch source {
        case .radarr, .whisparr: return .tmdb(externalId)
        case .sonarr:
            // A TMDB-sourced row has no tvdbId yet; `.tvdb(0)` would name nothing.
            if externalId == 0, let tmdbTVId { return .tmdbTV(tmdbTVId) }
            return .tvdb(externalId)
        case .lidarr:            return .musicBrainz(foreignId)
        }
    }
}

// MARK: - Search input

/// `.text` is keyword lookup ranked by relevance; `.ref` is an exact-id lookup that bypasses scoring.
nonisolated public enum SearchInput: Equatable, Sendable {
    case text(String)
    case ref(MediaRef)

    /// Radarr/Sonarr resolve `tmdb:N`/`tvdb:N`/`imdb:ttN` to a single record; `.text` passes through verbatim.
    public var arrTerm: String {
        switch self {
        case .text(let q):  return q
        case .ref(let ref): return ref.lookupTerm
        }
    }

    public var isRef: Bool {
        if case .ref = self { return true }
        return false
    }
}

// MARK: - Query parser

/// Recognises external-id prefixes; everything else is `.text`. Deliberately doesn't parse `(YYYY)`:
/// titles like "1917" or "Blade Runner 2049" make it cost more than it gives.
nonisolated enum QueryParser {
    static func parse(_ input: String) -> SearchInput {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = MediaRef(urlString: trimmed) {
            return .ref(ref)
        }
        return .text(trimmed)
    }
}
