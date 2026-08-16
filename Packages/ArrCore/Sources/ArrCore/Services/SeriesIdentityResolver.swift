import Foundation

/// The one place a TMDB **tv** id becomes a Sonarr-addressable series.
///
/// TMDB-sourced series rows (person filmography, `tmdb_discover_series`) carry
/// a TMDB tv id; Sonarr speaks tvdbId and nothing else. Every consumer used to
/// bridge that gap on its own by looking the show up **by title** and taking
/// the first hit — which is how "The Closer" opened a different "The Closer",
/// and, worse, how the add flow could write the wrong series into the library.
///
/// The rule here is that a substitution must be *proven*, never guessed:
///
/// 1. **The library snapshot.** Anything the user owns already has both ids in
///    memory (`ArrLibraryMaps.sonarrTVDBByTMDBId`) — zero requests.
/// 2. **Sonarr `term=tmdb:N`.** One request that resolves *and* enriches, but
///    only when the record that comes back actually carries that tmdb id.
///    Older Sonarr treats the unknown prefix as literal search text and
///    answers with whatever the string fuzzy-matches, so the gate is what
///    makes this path safe; a server that fails it is remembered and not
///    asked again this session.
/// 3. **TMDB `/tv/{id}/external_ids`** → tvdbId → an exact `tvdb:N` lookup.
/// 4. **Nothing.** No tvdb id, no substitution — callers keep the lean-but-
///    correct TMDB row, and the add flow refuses rather than posting a guess.
///
/// Cost shape: rendering a 100-row filmography costs nothing here (resolution
/// is lazy, on tap), and TMDB is only consulted for titles the user does *not*
/// own. Results are held in a small session LRU with in-flight coalescing —
/// the same pattern as `CastProvider`, whose cache this deliberately mirrors.
@MainActor
enum SeriesIdentityResolver {
    private static var recordCache: [String: SearchResult] = [:]
    private static var tvdbCache: [Int: Int] = [:]
    private static var lru: [String] = []
    private static var inflight: [String: Task<SearchResult?, Never>] = [:]
    private static let capacity = 40

    /// Per-server memory of whether Sonarr understood `term=tmdb:N`. Keyed by
    /// the config fingerprint so switching servers re-probes. `false` skips
    /// step 2 outright, so an old Sonarr costs one wasted request per session,
    /// not one per title.
    private static var acceptsTMDBTerm: [String: Bool] = [:]

    #if DEBUG
    /// Tests hand in an ephemeral session carrying only their own stub.
    /// Several suites register process-wide `URLProtocol`s whose `canInit`
    /// answers *every* request, so relying on global registration makes a
    /// resolution test pass alone and fail in a full run.
    static var sessionOverrideForTesting: URLSession?
    private static var session: URLSession { sessionOverrideForTesting ?? .shared }
    #else
    private static var session: URLSession { .shared }
    #endif

    // MARK: - Public API

    /// Sonarr's own record for a TMDB tv id — the enriched row (real tvdbId,
    /// IMDB/runtime/network) the add panel wants. Nil when identity can't be
    /// proven, and nil means "keep what you have", never "pick something".
    static func sonarrRecord(
        tmdbTVId: Int, sonarrConfig: ServiceConfig, tmdbKey: String
    ) async -> SearchResult? {
        guard tmdbTVId > 0, !DemoMode.isActive, sonarrConfig.isConfigured else { return nil }
        let key = "\(Self.fingerprint(sonarrConfig)):\(tmdbTVId)"
        if let hit = recordCache[key] { touch(key); return hit }
        if let running = inflight[key] { return await running.value }
        let task = Task<SearchResult?, Never> {
            await resolveRecord(tmdbTVId: tmdbTVId, sonarrConfig: sonarrConfig, tmdbKey: tmdbKey)
        }
        inflight[key] = task
        let record = await task.value
        inflight[key] = nil
        if let record {
            recordCache[key] = record
            if record.id > 0 { tvdbCache[tmdbTVId] = record.id }
            touch(key)
            trim()
        }
        return record
    }

    /// Just the tvdbId — for the add path, which needs the id Sonarr posts
    /// against and nothing else. Cheapest route first: an owned series answers
    /// from the library snapshot without a single request.
    static func tvdbId(
        tmdbTVId: Int, sonarrConfig: ServiceConfig, tmdbKey: String
    ) async -> Int? {
        guard tmdbTVId > 0, !DemoMode.isActive else { return nil }
        if let cached = tvdbCache[tmdbTVId] { return cached }
        if sonarrConfig.isConfigured,
           let owned = await ArrLibraryMaps.sonarrTVDBByTMDBId(config: sonarrConfig)[tmdbTVId] {
            tvdbCache[tmdbTVId] = owned
            return owned
        }
        if let resolved = await externalTVDBId(tmdbTVId: tmdbTVId, tmdbKey: tmdbKey) {
            return resolved
        }
        // Last resort is still an id route, not a title one: Sonarr may know
        // the tmdb id even when TMDB has no tvdb id on file.
        return await sonarrRecord(
            tmdbTVId: tmdbTVId, sonarrConfig: sonarrConfig, tmdbKey: tmdbKey
        ).map(\.id).flatMap { $0 > 0 ? $0 : nil }
    }

    // MARK: - Resolution

    private static func resolveRecord(
        tmdbTVId: Int, sonarrConfig: ServiceConfig, tmdbKey: String
    ) async -> SearchResult? {
        let client = SearchClient(config: sonarrConfig, source: .sonarr, session: session)

        // 1. Free: the user already owns it, so both ids are in the snapshot.
        if let owned = await ArrLibraryMaps.sonarrTVDBByTMDBId(config: sonarrConfig)[tmdbTVId] {
            tvdbCache[tmdbTVId] = owned
            if let record = await lookupTVDB(owned, client: client) { return record }
        }

        // 2. One request that both resolves and enriches — if this Sonarr
        //    understands the prefix, and if the answer proves it did.
        let fingerprint = Self.fingerprint(sonarrConfig)
        if acceptsTMDBTerm[fingerprint] != false {
            let candidates = (try? await client.lookup(query: "tmdb:\(tmdbTVId)")) ?? []
            if let hit = candidates.first(where: { $0.tmdbTVId == tmdbTVId && $0.id > 0 }) {
                acceptsTMDBTerm[fingerprint] = true
                return hit
            }
            // Either the server searched the literal string, or it knows the
            // prefix but not this show. Only the first is worth remembering,
            // and an empty/garbage answer can't tell them apart — so treat a
            // *populated but unverified* answer as "prefix unsupported".
            acceptsTMDBTerm[fingerprint] = candidates.isEmpty ? nil : false
        }

        // 3. TMDB's own cross-reference, then an exact lookup.
        guard let tvdb = await externalTVDBId(tmdbTVId: tmdbTVId, tmdbKey: tmdbKey) else {
            return nil
        }
        return await lookupTVDB(tvdb, client: client)
    }

    /// `/tv/{id}/external_ids`, memoised. The only TMDB request this type ever
    /// makes, and only for titles that missed both cheaper routes.
    private static func externalTVDBId(tmdbTVId: Int, tmdbKey: String) async -> Int? {
        if let cached = tvdbCache[tmdbTVId] { return cached }
        guard !tmdbKey.isEmpty,
              let tvdb = try? await TMDBClient(apiKey: tmdbKey, session: session).tvdbIdFromTVId(tmdbTVId),
              tvdb > 0
        else { return nil }
        tvdbCache[tmdbTVId] = tvdb
        return tvdb
    }

    /// Exact `tvdb:N` lookup, verified against the id we asked for. Sonarr
    /// resolves the ref server-side, so a mismatch means something odd came
    /// back and we'd rather have nothing.
    private static func lookupTVDB(_ tvdbId: Int, client: SearchClient) async -> SearchResult? {
        let candidates = (try? await client.lookup(input: .ref(.tvdb(tvdbId)))) ?? []
        return candidates.first { $0.id == tvdbId }
    }

    // MARK: - Cache

    private static func fingerprint(_ config: ServiceConfig) -> String {
        "\(config.baseURL)|\(config.apiKey.count)"
    }

    private static func touch(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    private static func trim() {
        while lru.count > capacity {
            let evicted = lru.removeFirst()
            recordCache[evicted] = nil
        }
    }

    #if DEBUG
    /// Tests share one process; identity caches must not leak between them.
    static func resetForTesting() {
        sessionOverrideForTesting = nil
        recordCache = [:]
        tvdbCache = [:]
        lru = []
        inflight = [:]
        acceptsTMDBTerm = [:]
    }
    #endif
}
