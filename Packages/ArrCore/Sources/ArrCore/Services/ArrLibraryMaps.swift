import Foundation

/// Ownership cross-reference maps: an external id (TMDB / TVDB) → the arr's own
/// record id, so TMDB-sourced results (chat discovery, person filmography) can
/// be tagged as already-in-library and routed to the detail view instead of the
/// add flow. Extracted so the chat tools and the person view build them the
/// same way instead of each looping the library.
public enum ArrLibraryMaps {
    /// Radarr: `tmdbId → movie.id`. Empty when Radarr isn't configured or the
    /// fetch fails — callers proceed untagged.
    public static func radarrByTMDBId(config: ServiceConfig) async -> [Int: Int] {
        guard config.isConfigured else { return [:] }
        guard let library = try? await RadarrClient(config: config).fetchAllMovies() else { return [:] }
        var map: [Int: Int] = [:]
        for rec in library {
            if let tmdb = rec.tmdbId, let arrId = rec.id { map[tmdb] = arrId }
        }
        return map
    }

    /// Sonarr: `tvdbId → series.id`. Only flows that carry real tvdbIds can use
    /// this — TMDB-tv ids are not tvdb ids.
    public static func sonarrByTVDBId(config: ServiceConfig) async -> [Int: Int] {
        guard config.isConfigured else { return [:] }
        guard let library = try? await SonarrClient(config: config).fetchAllSeries() else { return [:] }
        var map: [Int: Int] = [:]
        for rec in library {
            if let tvdb = rec.tvdbId, let arrId = rec.id { map[tvdb] = arrId }
        }
        return map
    }
}
