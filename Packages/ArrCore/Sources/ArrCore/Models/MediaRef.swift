import Foundation

/// Stable cross-system identity for a media item.
///
/// Different arr sources use different external ID schemes:
///   - **TMDB ID** — Radarr (movies), Whisparr (scenes)
///   - **TVDB ID** — Sonarr (series)
///   - **MusicBrainz ID** — Lidarr (artists / albums; GUID-string)
///   - **IMDB ID** — universal cross-reference (`tt`-prefixed string)
///
/// Wrapping these in an enum lets call sites carry the *kind* of ID
/// along with the value, instead of passing bare `Int`/`String` and
/// hoping the receiver knows which scheme is in play. Used by:
///
///   - Search ranking — `SearchInput.ref(_:)` bypasses text scoring
///     when the user typed `tmdb:12345`
///   - Detail navigation — `DetailRequest.syntheticItem(ref:...)`
///   - Chat tool payloads — JSON shape carries `"tmdb:12345"` so the
///     UI can route a tap to the right detail surface
///   - Add flow — pattern-matched dispatch to the right arr client
///     (`addMovie(tmdbId:)` vs `addSeries(tvdbId:)` etc.)
public enum MediaRef: Hashable, Sendable {
    case tmdb(Int)
    case tvdb(Int)
    /// TMDB's **series** id — a different id space from `.tmdb`, which is
    /// TMDB's movie id. Kept as its own case rather than reusing `.tmdb`
    /// precisely because the two are not interchangeable: the same number
    /// names a different title in each, and conflating them is how a link
    /// ends up opening something else entirely.
    ///
    /// No arr resolves this directly (see `compatibleSources`) — it must go
    /// through `SeriesIdentityResolver` to become a `.tvdb` ref first.
    case tmdbTV(Int)
    case musicBrainz(String)
    case imdb(String)        // "ttNNNNNNN" — verbatim, including prefix

    /// Which arr sources can resolve this ref to a library record.
    /// Used by the search ranker to decide whether a ref-typed query
    /// is compatible with each per-source result list.
    public var compatibleSources: Set<QueueItem.Source> {
        switch self {
        case .tmdb:        return [.radarr, .whisparr]
        case .tvdb:        return [.sonarr]
        // Deliberately empty, and a safety rail rather than an omission: no
        // arr can look a TMDB series id up. An empty set makes
        // `lookup(input: .ref(_:))` short-circuit and `ensureRefCompatible`
        // refuse, so the only way from here to Sonarr is through
        // `SeriesIdentityResolver` — which proves the identity instead of
        // matching a title.
        case .tmdbTV:      return []
        case .musicBrainz: return [.lidarr]
        // Both Radarr and Sonarr accept `imdb:ttN` on /lookup. Asking a
        // server that doesn't is harmless now that the ranker matches on the
        // record's own `imdbId`: a title search for the literal "imdb:ttN"
        // returns nothing that can pass that check.
        case .imdb:        return [.radarr, .sonarr]
        }
    }

    /// String form for arr's `/lookup?term=` endpoint and for
    /// notification URLs. Matches the prefixed shape the user can
    /// also type into the search bar.
    ///
    /// `musicBrainz` returns the bare GUID — Lidarr's /lookup keys
    /// on it directly without a prefix, unlike the TMDB/TVDB
    /// `<scheme>:` form.
    public var lookupTerm: String {
        switch self {
        case .tmdb(let id):        return "tmdb:\(id)"
        case .tvdb(let id):        return "tvdb:\(id)"
        // Sonarr's SkyHook understands this on newer versions and treats it
        // as literal search text on older ones, so nothing may trust the
        // answer without checking the record's own tmdbId — which is
        // `SeriesIdentityResolver`'s job. `compatibleSources` is empty, so no
        // plain `.ref(_:)` lookup ever reaches an arr with this term.
        case .tmdbTV(let id):      return "tmdb:\(id)"
        case .musicBrainz(let id): return id
        case .imdb(let id):        return "imdb:\(id)"
        }
    }

    /// Round-trippable URL form for deep links and chat-tool JSON.
    /// `"tmdb:12345"` / `"imdb:tt0123456"` / `"mb:<guid>"` /
    /// `"tvdb:67890"`. Distinct from `lookupTerm` for MusicBrainz —
    /// the URL form needs a scheme so the parser can recognise it,
    /// even though arr's endpoint takes a bare GUID.
    public var urlString: String {
        switch self {
        case .tmdb(let id):        return "tmdb:\(id)"
        case .tvdb(let id):        return "tvdb:\(id)"
        // Its own scheme, not "tmdb:", because the two id spaces disagree
        // about what any given number means — a round-trip through a shared
        // scheme would silently turn a series into some unrelated movie.
        case .tmdbTV(let id):      return "tmdbtv:\(id)"
        case .musicBrainz(let id): return "mb:\(id)"
        case .imdb(let id):        return "imdb:\(id)"
        }
    }

    /// False for a ref whose id slot is empty — `.tvdb(0)` and friends, which
    /// a row that couldn't identify itself still produces. Such a ref must
    /// never be printed for the model or handed to a router: it looks like an
    /// id and resolves to nothing.
    public var isAddressable: Bool {
        switch self {
        case .tmdb(let id), .tvdb(let id), .tmdbTV(let id): return id > 0
        case .musicBrainz(let id): return !id.isEmpty
        case .imdb(let id):        return id.count > 2
        }
    }

    /// Inverse of `urlString` — parse `"tmdb:12345"` / `"tvdb:N"` /
    /// `"mb:<guid>"` / `"imdb:ttN"` back into a `MediaRef`. Nil for
    /// any malformed input. Used by `QueryParser` and by deep-link
    /// routing.
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
            // Sanity: MBIDs are 36-char GUIDs ("xxxxxxxx-xxxx-..."),
            // but Lidarr also accepts other foreign-id forms in some
            // catalog edges. Don't over-validate — accept any
            // non-empty payload and let the arr endpoint reject if
            // it's actually malformed.
            self = .musicBrainz(value)
        case "imdb":
            // IMDB IDs are "tt" + digits. Be lenient — accept either
            // "imdb:tt0123456" (canonical) or "imdb:0123456" (caller
            // forgot the prefix) and normalise the latter.
            let normalised = value.hasPrefix("tt") ? value : "tt\(value)"
            self = .imdb(normalised)
        default:
            return nil
        }
    }
}

// MARK: - SearchResult bridge

public extension SearchResult {
    /// Source-aware canonical identity. Lets call sites compare or
    /// route by `MediaRef` without re-deriving the scheme from
    /// `source` + `id` everywhere.
    var mediaRef: MediaRef {
        switch source {
        case .radarr, .whisparr: return .tmdb(id)
        case .sonarr:
            // A TMDB-sourced row has no tvdbId yet (`id` is still 0) but does
            // know which show it is. Saying so — rather than reporting
            // `.tvdb(0)`, an id that names nothing — is what lets these rows be
            // linked and routed at all.
            if id == 0, let tmdbTVId { return .tmdbTV(tmdbTVId) }
            return .tvdb(id)
        case .lidarr:            return .musicBrainz(foreignId)
        }
    }
}

// MARK: - Search input

/// What the user actually wants when they type into the search bar.
/// `text` is plain keyword lookup; `ref` is "open this specific
/// thing" via an external ID prefix. The two cases have different
/// ranking semantics (text → relevance score, ref → exact-match
/// bypass) and the call sites that consume `SearchInput` switch on
/// the case rather than re-parsing the original string.
public enum SearchInput: Equatable, Sendable {
    case text(String)
    case ref(MediaRef)

    /// String we pass to arr's `/lookup?term=` endpoint.
    /// Radarr/Sonarr natively understand `tmdb:N`/`tvdb:N`/`imdb:ttN`
    /// and resolve to a single record; for `.text` we pass through
    /// verbatim.
    public var arrTerm: String {
        switch self {
        case .text(let q):  return q
        case .ref(let ref): return ref.lookupTerm
        }
    }

    /// True for `.ref(_:)` — caller can short-circuit rendering
    /// affordances that don't make sense for an exact-id query
    /// (e.g. cross-source merge stays a no-op if only one source
    /// will return a record).
    public var isRef: Bool {
        if case .ref = self { return true }
        return false
    }
}

// MARK: - Query parser

/// Single entry point for "what did the user type". Recognises
/// external-id prefixes; everything else falls through as `.text`.
///
/// Deliberately does **not** parse `(YYYY)` year tokens — the
/// 1917-as-year-not-title ambiguity and the related "Blade Runner
/// 2049" cases burn more value than the feature provides. If a year
/// filter is ever needed, add it as an explicit UI control rather
/// than parsing it out of the free-text field.
public enum QueryParser {
    public static func parse(_ input: String) -> SearchInput {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = MediaRef(urlString: trimmed) {
            return .ref(ref)
        }
        return .text(trimmed)
    }
}
