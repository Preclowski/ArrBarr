import Foundation
import os
import MediaKit

/// Turns a TMDB tv id into a Sonarr series only when proven, never by title:
/// library snapshot, then verified `term=tmdb:N`, then TMDB external_ids → `tvdb:N`.
enum SeriesIdentityResolver {
    /// Artwork differs between TMDB and TVDB for the same series; only the ids tell.
    private static let log = Logger(category: "SeriesIdentity")

    /// Keyed per server: an old Sonarr treats `tmdb:` as literal text, so it's asked once per session.
    private static var acceptsTMDBTerm: [String: Bool] = [:]

    // MARK: - Public API

    /// Nil when identity can't be proven, meaning "keep what you have", never "pick something".
    static func sonarrRecord(
        tmdbTVId: Int, sonarrConfig: ServiceConfig, tmdbKey: String
    ) async -> SearchResult? {
        guard tmdbTVId > 0, sonarrConfig.isConfigured else { return nil }
        return await resolveRecord(tmdbTVId: tmdbTVId, sonarrConfig: sonarrConfig, tmdbKey: tmdbKey)
    }

    static func tvdbId(
        tmdbTVId: Int, sonarrConfig: ServiceConfig, tmdbKey: String
    ) async -> Int? {
        guard tmdbTVId > 0 else { return nil }
        if let known = await knownTVDBId(tmdbTVId) { return known }
        if sonarrConfig.isConfigured,
           let owned = await ArrLibraryMaps.sonarrTVDBByTMDBId(config: sonarrConfig)[tmdbTVId] {
            return owned
        }
        if let external = await externalTVDBId(tmdbTVId: tmdbTVId, tmdbKey: tmdbKey) {
            return external
        }
        // Sonarr may know the tmdb id even when TMDB has no tvdb id on file.
        let record = await sonarrRecord(
            tmdbTVId: tmdbTVId, sonarrConfig: sonarrConfig, tmdbKey: tmdbKey)
        return (record?.externalId).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func knownTVDBId(_ tmdbTVId: Int) async -> Int? {
        await ServiceGateway.resolve().known(.tmdbSeries(tmdbTVId), in: .tvdb)?.intValue
    }

    // MARK: - Resolution

    private static func resolveRecord(
        tmdbTVId: Int, sonarrConfig: ServiceConfig, tmdbKey: String
    ) async -> SearchResult? {
        let client = SearchClient(config: sonarrConfig, source: .sonarr)

        if let owned = await knownTVDBId(tmdbTVId), let record = await lookupTVDB(owned, client: client) {
            logResolution(tmdbTVId, record, via: "crosswalk")
            return record
        }
        if let owned = await ArrLibraryMaps.sonarrTVDBByTMDBId(config: sonarrConfig)[tmdbTVId] {
            if let record = await lookupTVDB(owned, client: client) {
                logResolution(tmdbTVId, record, via: "library")
                return record
            }
        }

        let fingerprint = sonarrConfig.identityFingerprint
        if acceptsTMDBTerm[fingerprint] != false {
            let candidates = await log.attempt("sonarr tmdb: lookup", level: .default) { try await client.lookup(query: MediaRef.tmdbTV(tmdbTVId).lookupTerm) } ?? []
            if let hit = candidates.first(where: { $0.tmdbTVId == tmdbTVId && $0.externalId > 0 }) {
                acceptsTMDBTerm[fingerprint] = true
                logResolution(tmdbTVId, hit, via: "sonarr tmdb: term")
                return hit
            }
            // Empty can't tell "literal search" from "unknown show"; only a populated
            // unverified answer proves the prefix is unsupported.
            acceptsTMDBTerm[fingerprint] = candidates.isEmpty ? nil : false
        }

        guard let tvdb = await externalTVDBId(tmdbTVId: tmdbTVId, tmdbKey: tmdbKey) else {
            // A gap in TMDB's data, not our failure: `.notice`, not `.error`.
            log.notice("tmdb tv \(tmdbTVId, privacy: .public): unresolved — no tvdb id, nothing substituted")
            return nil
        }
        let record = await lookupTVDB(tvdb, client: client)
        if let record {
            logResolution(tmdbTVId, record, via: "tmdb external_ids")
        } else {
            log.notice("tmdb tv \(tmdbTVId, privacy: .public) → tvdb \(tvdb, privacy: .public): sonarr returned no matching record")
        }
        return record
    }

    /// The ids settle "same show?", so the title can stay `.private`.
    private static func logResolution(_ tmdbTVId: Int, _ record: SearchResult, via route: String) {
        log.notice("""
            tmdb tv \(tmdbTVId, privacy: .public) → tvdb \(record.externalId, privacy: .public) \
            "\(record.title, privacy: .private)" (\(record.year ?? 0, privacy: .public)) via \(route, privacy: .public)
            """)
    }

    /// The only TMDB request this type makes, for titles that missed the cheaper routes.
    private static func externalTVDBId(tmdbTVId: Int, tmdbKey: String) async -> Int? {
        guard !tmdbKey.isEmpty,
              let tvdb = await log.attempt("TMDB external ids", level: .default, { try await TMDBClient(apiKey: tmdbKey).tvdbIdFromTVId(tmdbTVId) }) ?? nil,
              tvdb > 0
        else { return nil }
        return tvdb
    }

    /// A mismatch means something odd came back; nothing is better.
    private static func lookupTVDB(_ tvdbId: Int, client: SearchClient) async -> SearchResult? {
        let candidates = await log.attempt("sonarr tvdb: lookup", level: .default) { try await client.lookup(input: .ref(.tvdb(tvdbId))) } ?? []
        return candidates.first { $0.externalId == tvdbId }
    }

    #if DEBUG
    /// Tests share one process; identity caches must not leak between them.
    // periphery:ignore
    static func resetForTesting() {
        acceptsTMDBTerm = [:]
    }
    #endif
}
