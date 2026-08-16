import Foundation
import os

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
/// own. Results are held in a `CoalescingCache`, so a second tap on the same
/// title — or two taps racing — costs nothing.
@MainActor
enum SeriesIdentityResolver {
    /// Nil is a *miss*, not an answer: a title we couldn't prove today may
    /// resolve once Sonarr is reachable or the TMDB key is pasted.
    private static let records = CoalescingCache<String, SearchResult?>(
        capacity: 40, shouldStore: { $0 != nil })
    /// `tmdbTVId → tvdbId`, the half of a resolution the add path needs on its
    /// own. Separate from `records` because it is also filled by the library
    /// snapshot, which answers without ever producing a Sonarr record.
    private static let tvdbIds = CoalescingCache<Int, Int?>(
        capacity: 200, shouldStore: { $0 != nil })

    /// Every resolution is logged with both ids and the title it landed on.
    /// "Is this the same show?" is not answerable by looking at a poster —
    /// artwork differs between TMDB and TVDB for the *same* series — so the
    /// answer has to come from the ids, and this is where they are known.
    private static let log = Logger(subsystem: AppLog.subsystem, category: "SeriesIdentity")

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
        let record = await records.value(for: "\(sonarrConfig.identityFingerprint):\(tmdbTVId)") {
            await resolveRecord(tmdbTVId: tmdbTVId, sonarrConfig: sonarrConfig, tmdbKey: tmdbKey)
        }
        // A resolved record is also the answer to "what is its tvdbId", so the
        // add path never re-resolves what the panel already worked out.
        if let id = record?.id, id > 0 { tvdbIds.store(id, for: tmdbTVId) }
        return record
    }

    /// Just the tvdbId — for the add path, which needs the id Sonarr posts
    /// against and nothing else. Cheapest route first: an owned series answers
    /// from the library snapshot without a single request.
    static func tvdbId(
        tmdbTVId: Int, sonarrConfig: ServiceConfig, tmdbKey: String
    ) async -> Int? {
        guard tmdbTVId > 0, !DemoMode.isActive else { return nil }
        return await tvdbIds.value(for: tmdbTVId) {
            // Cheapest first: an owned series has both ids in the library
            // snapshot already, so this costs no request at all.
            if sonarrConfig.isConfigured,
               let owned = await ArrLibraryMaps.sonarrTVDBByTMDBId(config: sonarrConfig)[tmdbTVId] {
                return owned
            }
            if let external = await externalTVDBId(tmdbTVId: tmdbTVId, tmdbKey: tmdbKey) {
                return external
            }
            // Still an id route, not a title one: Sonarr may know the tmdb id
            // even when TMDB has no tvdb id on file.
            let record = await sonarrRecord(
                tmdbTVId: tmdbTVId, sonarrConfig: sonarrConfig, tmdbKey: tmdbKey)
            return (record?.id).flatMap { $0 > 0 ? $0 : nil }
        }
    }

    // MARK: - Resolution

    private static func resolveRecord(
        tmdbTVId: Int, sonarrConfig: ServiceConfig, tmdbKey: String
    ) async -> SearchResult? {
        let client = SearchClient(config: sonarrConfig, source: .sonarr, session: session)

        // 1. Free: the user already owns it, so both ids are in the snapshot.
        if let owned = await ArrLibraryMaps.sonarrTVDBByTMDBId(config: sonarrConfig)[tmdbTVId] {
            if let record = await lookupTVDB(owned, client: client) {
                logResolution(tmdbTVId, record, via: "library")
                return record
            }
        }

        // 2. One request that both resolves and enriches — if this Sonarr
        //    understands the prefix, and if the answer proves it did.
        let fingerprint = sonarrConfig.identityFingerprint
        if acceptsTMDBTerm[fingerprint] != false {
            let candidates = (try? await client.lookup(query: MediaRef.tmdbTV(tmdbTVId).lookupTerm)) ?? []
            if let hit = candidates.first(where: { $0.tmdbTVId == tmdbTVId && $0.id > 0 }) {
                acceptsTMDBTerm[fingerprint] = true
                logResolution(tmdbTVId, hit, via: "sonarr tmdb: term")
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
            log.error("tmdb tv \(tmdbTVId, privacy: .public): unresolved — no tvdb id, nothing substituted")
            return nil
        }
        let record = await lookupTVDB(tvdb, client: client)
        if let record {
            logResolution(tmdbTVId, record, via: "tmdb external_ids")
        } else {
            log.error("tmdb tv \(tmdbTVId, privacy: .public) → tvdb \(tvdb, privacy: .public): sonarr returned no matching record")
        }
        return record
    }

    /// One line per resolution, naming both ids, the route and what came back
    /// — enough to settle "same show or not?" from the log alone.
    ///
    /// `.notice`, not `.info`: macOS keeps info-level messages in memory only,
    /// so they are gone by the time anyone runs `log show` and the evidence
    /// exists only if someone happened to be streaming at that second. A
    /// diagnostic you cannot read afterwards is not a diagnostic.
    private static func logResolution(_ tmdbTVId: Int, _ record: SearchResult, via route: String) {
        log.notice("""
            tmdb tv \(tmdbTVId, privacy: .public) → tvdb \(record.id, privacy: .public) \
            "\(record.title, privacy: .public)" (\(record.year ?? 0, privacy: .public)) via \(route, privacy: .public)
            """)
    }

    /// `/tv/{id}/external_ids` — the only TMDB request this type ever makes,
    /// and only for titles that missed both cheaper routes. Memoisation lives
    /// in `tvdbIds`, which wraps every route into this one.
    private static func externalTVDBId(tmdbTVId: Int, tmdbKey: String) async -> Int? {
        guard !tmdbKey.isEmpty,
              let tvdb = try? await TMDBClient(apiKey: tmdbKey, session: session).tvdbIdFromTVId(tmdbTVId),
              tvdb > 0
        else { return nil }
        return tvdb
    }

    /// Exact `tvdb:N` lookup, verified against the id we asked for. Sonarr
    /// resolves the ref server-side, so a mismatch means something odd came
    /// back and we'd rather have nothing.
    private static func lookupTVDB(_ tvdbId: Int, client: SearchClient) async -> SearchResult? {
        let candidates = (try? await client.lookup(input: .ref(.tvdb(tvdbId)))) ?? []
        return candidates.first { $0.id == tvdbId }
    }

    #if DEBUG
    /// Tests share one process; identity caches must not leak between them.
    static func resetForTesting() {
        sessionOverrideForTesting = nil
        records.removeAll()
        tvdbIds.removeAll()
        acceptsTMDBTerm = [:]
    }
    #endif
}
