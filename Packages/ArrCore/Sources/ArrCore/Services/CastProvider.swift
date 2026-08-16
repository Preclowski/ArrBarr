import Foundation

/// The single source of cast strips across the app. Replaces the three
/// near-identical fetchers that used to live in `DetailView` (movie + series)
/// and `SearchAddPanel`, adds a small per-title cache so the add panel and the
/// detail view of the same title stop double-fetching, and coalesces
/// concurrent requests for the same title into one network call.
///
/// Movies come from Radarr's `/credit` when we have a Radarr id (no TMDB key
/// needed), falling back to TMDB. Series have no Radarr endpoint, so they come
/// from TMDB — by the series' `tmdbId`, or resolved from its `tvdbId` via
/// `/find` when Sonarr didn't ship a tmdbId (the fix for series that showed no
/// cast at all).
@MainActor
enum CastProvider {
    /// Misses stay uncached (see `CoalescingCache`): an empty strip is usually
    /// a transient "not ready yet" — an unreleased title with no credits, or a
    /// fetch blip — and pinning it would keep the row empty all session.
    private static let cache = CoalescingCache<String, [CastMember]>(
        capacity: 40, shouldStore: { !$0.isEmpty })

    // MARK: - Public API

    /// Movie cast. `radarrMovieId` takes Radarr's `/credit` path (works with no
    /// TMDB key, and in demo); `tmdbId` is the fallback / the only route when
    /// the caller has no Radarr id (e.g. a TMDB-sourced add-panel result).
    static func movieCast(radarrMovieId: Int?, tmdbId: Int?, configStore: ConfigStore) async -> [CastMember] {
        let key = "movie:\(radarrMovieId.map(String.init) ?? "-"):\(tmdbId.map(String.init) ?? "-")"
        return await cache.value(for: key) {
            await fetchMovieCast(radarrMovieId: radarrMovieId, tmdbId: tmdbId, configStore: configStore)
        }
    }

    /// Series cast. `tmdbId` is tried first; when absent, `tvdbId` is resolved
    /// to a tmdb id via TMDB `/find`. `demoSeriesId` serves demo fixtures.
    static func seriesCast(tmdbId: Int?, tvdbId: Int?, demoSeriesId: Int?, configStore: ConfigStore) async -> [CastMember] {
        let key = "series:\(tmdbId.map(String.init) ?? "-"):\(tvdbId.map(String.init) ?? "-"):\(demoSeriesId.map(String.init) ?? "-")"
        return await cache.value(for: key) {
            await fetchSeriesCast(tmdbId: tmdbId, tvdbId: tvdbId, demoSeriesId: demoSeriesId, configStore: configStore)
        }
    }

    // MARK: - Fetchers (the logic the three call sites used to duplicate)

    private static func fetchMovieCast(radarrMovieId: Int?, tmdbId: Int?, configStore: ConfigStore) async -> [CastMember] {
        // Radarr `/credit` first — it needs no TMDB key and serves demo. Only
        // usable when the caller has a Radarr movie id (the detail view does;
        // a TMDB-search add-panel result does not).
        if let radarrMovieId, DemoMode.isActive || configStore.radarr.isConfigured {
            let credits = (try? await RadarrClient(config: configStore.radarr).fetchCredits(movieId: radarrMovieId)) ?? []
            let members = CastMember.from(radarrCredits: credits)
            if !members.isEmpty { return members }
            // Radarr frequently has no credits for unreleased movies — fall
            // through to TMDB when we can.
        }
        guard !DemoMode.isActive else { return [] }
        let key = configStore.tmdbApiKey
        guard !key.isEmpty, let tmdbId, tmdbId > 0,
              let credits = try? await TMDBClient(apiKey: key).movieCredits(movieId: tmdbId)
        else { return [] }
        return CastMember.from(tmdbCast: credits.cast)
    }

    private static func fetchSeriesCast(tmdbId: Int?, tvdbId: Int?, demoSeriesId: Int?, configStore: ConfigStore) async -> [CastMember] {
        if DemoMode.isActive {
            return demoSeriesId.map { DemoMocks.sonarrSeriesCast(seriesId: $0) } ?? []
        }
        let key = configStore.tmdbApiKey
        guard !key.isEmpty else { return [] }
        let client = TMDBClient(apiKey: key)
        // Prefer the tmdb id; otherwise resolve it from the tvdb id. This
        // second path is why series with no `tmdbId` from Sonarr now get cast.
        var resolvedTmdbId = tmdbId
        if resolvedTmdbId == nil || resolvedTmdbId == 0, let tvdbId, tvdbId > 0 {
            resolvedTmdbId = try? await client.tvIdFromTVDB(tvdbId)
        }
        guard let id = resolvedTmdbId, id > 0,
              let credits = try? await client.tvCredits(tvId: id)
        else { return [] }
        return CastMember.from(tmdbCast: credits.cast)
    }
}
