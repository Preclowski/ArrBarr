import Foundation

/// Ownership cross-reference maps: an external id (TMDB / TVDB) → the title's
/// `LibraryOwnership` (arr record id + whether it's downloaded), so results
/// from any source (search, chat discovery, person filmography, Quiz) can be
/// tagged as already-in-library, routed to the detail view instead of the add
/// flow, and show the right ownership chip. Extracted so every caller builds
/// the maps the same way instead of each looping the library.
///
/// All maps read `LibraryIndex`, so the callers that used to fetch a whole
/// library each — search, `suggest_titles`, `discover_in_quiz` and the TMDB
/// credit tools — share one snapshot instead of pulling a 3000-movie payload
/// apiece.
nonisolated public enum ArrLibraryMaps {
    /// Radarr: `tmdbId → ownership`. Empty when Radarr isn't configured or the
    /// fetch fails — callers proceed untagged.
    public static func radarrByTMDBId(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.movies(config: config) {
            if let tmdb = rec.tmdbId, let owned = rec.ownership { map[tmdb] = owned }
        }
        return map
    }

    /// Sonarr: `tvdbId → ownership`. Only flows that carry real tvdbIds can use
    /// this — TMDB-tv ids are not tvdb ids.
    public static func sonarrByTVDBId(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.series(config: config) {
            if let tvdb = rec.tvdbId, let owned = rec.ownership { map[tvdb] = owned }
        }
        return map
    }

    /// Sonarr: `tmdbId → ownership` — the TV counterpart of `radarrByTMDBId`,
    /// and what tags TMDB-sourced series rows as owned.
    ///
    /// This exists because the alternative was a title + year join, which is
    /// a guess: two different shows can share a name and a year. Sonarr has
    /// shipped `tmdbId` on the series resource all along; reading it turns
    /// that guess into an id match, at no extra request (the snapshot behind
    /// `LibraryIndex` is the same one every other map reads).
    public static func sonarrByTMDBId(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.series(config: config) {
            if let tmdb = rec.tmdbId, tmdb > 0, let owned = rec.ownership { map[tmdb] = owned }
        }
        return map
    }

    /// Sonarr: `tmdbId → tvdbId`, straight off the library snapshot.
    ///
    /// The free first step of series identity resolution: for anything the
    /// user already owns, both ids are in memory, so translating a TMDB row
    /// to the id Sonarr wants costs zero requests.
    public static func sonarrTVDBByTMDBId(config: ServiceConfig) async -> [Int: Int] {
        var map: [Int: Int] = [:]
        for rec in await LibraryIndex.shared.series(config: config) {
            if let tmdb = rec.tmdbId, tmdb > 0, let tvdb = rec.tvdbId, tvdb > 0 { map[tmdb] = tvdb }
        }
        return map
    }

    /// Stable positive `Int` key for a foreign STRING id (a MusicBrainz artist
    /// id, a Whisparr scene's `foreignId`). `SearchResult.externalId` is an
    /// Int, so the string ids get hashed into it — this is the one definition
    /// of that rule, and both sides of the ownership join must call it or
    /// every owned artist reads as addable.
    ///
    /// `hashValue` is not stable across process launches; it does not have to
    /// be. Both sides compute it in the same process, and nothing persists it.
    public static func foreignHashKey(_ foreignId: String) -> Int {
        abs(foreignId.hashValue) & 0x7fffffff
    }

    /// Lidarr: `hash(foreignArtistId) → ownership`, off the shared snapshot.
    public static func lidarrByForeignArtistHash(config: ServiceConfig) async -> [Int: LibraryOwnership] {
        var map: [Int: LibraryOwnership] = [:]
        for rec in await LibraryIndex.shared.artists(config: config) {
            if let fid = rec.foreignArtistId, let owned = rec.ownership {
                map[foreignHashKey(fid)] = owned
            }
        }
        return map
    }

    /// Whisparr: `tmdbId → ownership`, falling back to `hash(foreignId)` for
    /// the scene records that carry no TMDB id. Matches what
    /// `SearchClient.unifyWhisparr` stamps on the lookup rows.
    public static func whisparrByForeignId(config: ServiceConfig) async -> [Int: LibraryOwnership] {
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
