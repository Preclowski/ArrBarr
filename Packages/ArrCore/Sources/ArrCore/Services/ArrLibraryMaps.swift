import Foundation

/// Ownership maps from an external id (TMDB / TVDB) to `LibraryOwnership`, all
/// read off the shared `LibraryIndex` snapshot.
nonisolated enum ArrLibraryMaps {
    /// Empty when Radarr isn't configured or the fetch fails; callers proceed untagged.
    static func radarrByTMDBId(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.movies(config: config) {
            if let tmdb = rec.tmdbId, let owned = rec.ownership { map[tmdb] = owned }
        }
        return map
    }

    /// Only for flows with real tvdbIds: TMDB-tv ids are not tvdb ids.
    static func sonarrByTVDBId(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.series(config: config) {
            if let tvdb = rec.tvdbId, let owned = rec.ownership { map[tvdb] = owned }
        }
        return map
    }

    /// An id match instead of a title + year join, which two shows can share.
    static func sonarrByTMDBId(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.series(config: config) {
            if let tmdb = rec.tmdbId, tmdb > 0, let owned = rec.ownership { map[tmdb] = owned }
        }
        return map
    }

    /// Translating an owned TMDB row to Sonarr's id costs zero requests.
    static func sonarrTVDBByTMDBId(config: ServiceConfig) async -> [Int: Int] {
        var map: [Int: Int] = [:]
        for rec in await LibraryIndex.shared.series(config: config) {
            if let tmdb = rec.tmdbId, tmdb > 0, let tvdb = rec.tvdbId, tvdb > 0 { map[tmdb] = tvdb }
        }
        return map
    }

    /// `SearchResult.externalId` is an Int, so string ids are hashed; both sides of the join must use this.
    /// `hashValue` isn't stable across launches, which is fine: nothing persists it.
    static func foreignHashKey(_ foreignId: String) -> Int {
        abs(foreignId.hashValue) & 0x7fffffff
    }

    static func lidarrByForeignArtistHash(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.artists(config: config) {
            if let fid = rec.foreignArtistId, let owned = rec.ownership {
                map[foreignHashKey(fid)] = owned
            }
        }
        return map
    }

    /// Falls back to `hash(foreignId)` for scenes without a TMDB id, matching
    /// `SearchClient.unifyWhisparr`.
    static func whisparrByForeignId(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.whisparrMovies(config: config) {
            let key: Int? = {
                if let tmdbId = rec.tmdbId, tmdbId != 0 { return tmdbId }
                if let fid = rec.foreignId { return foreignHashKey(fid) }
                return nil
            }()
            if let key, let owned = rec.ownership { map[key] = owned }
        }
        return map
    }
}
