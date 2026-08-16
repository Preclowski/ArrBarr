import Foundation

/// Ownership cross-reference maps: an external id (TMDB / TVDB) → the arr's own
/// record id, so TMDB-sourced results (chat discovery, person filmography) can
/// be tagged as already-in-library and routed to the detail view instead of the
/// add flow. Extracted so the chat tools and the person view build them the
/// same way instead of each looping the library.
///
/// Both maps read `LibraryIndex`, so the four callers that used to fetch a
/// whole library each — `suggest_titles`, `discover_in_quiz` and the two TMDB
/// credit tools — now share one snapshot per turn instead of pulling a
/// 3000-movie payload apiece.
public enum ArrLibraryMaps {
    /// Radarr: `tmdbId → movie.id`. Empty when Radarr isn't configured or the
    /// fetch fails — callers proceed untagged.
    public static func radarrByTMDBId(config: ServiceConfig) async -> [Int: Int] {
        var map: [Int: Int] = [:]
        for rec in await LibraryIndex.shared.movies(config: config) {
            if let tmdb = rec.tmdbId, let arrId = rec.id { map[tmdb] = arrId }
        }
        return map
    }

    /// Sonarr: `tvdbId → series.id`. Only flows that carry real tvdbIds can use
    /// this — TMDB-tv ids are not tvdb ids.
    public static func sonarrByTVDBId(config: ServiceConfig) async -> [Int: Int] {
        var map: [Int: Int] = [:]
        for rec in await LibraryIndex.shared.series(config: config) {
            if let tvdb = rec.tvdbId, let arrId = rec.id { map[tvdb] = arrId }
        }
        return map
    }

    /// Sonarr: `tmdbId → series.id` — the TV counterpart of
    /// `radarrByTMDBId`, and what tags TMDB-sourced series rows as owned.
    ///
    /// This exists because the alternative was a title + year join, which is
    /// a guess: two different shows can share a name and a year. Sonarr has
    /// shipped `tmdbId` on the series resource all along; reading it turns
    /// that guess into an id match, at no extra request (the snapshot behind
    /// `LibraryIndex` is the same one every other map reads).
    public static func sonarrByTMDBId(config: ServiceConfig) async -> [Int: Int] {
        var map: [Int: Int] = [:]
        for rec in await LibraryIndex.shared.series(config: config) {
            if let tmdb = rec.tmdbId, tmdb > 0, let arrId = rec.id { map[tmdb] = arrId }
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
}
