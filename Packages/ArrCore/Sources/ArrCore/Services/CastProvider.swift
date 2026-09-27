import Foundation

/// Cast + directing credits for one title, as the detail surfaces render them.
/// Fetched together because both come out of the same credits payload — asking
/// for them separately would double every request.
struct TitleCredits: Equatable, Sendable {
    var cast: [CastMember] = []
    /// Movies: the crew credited with directing. Series: the creators — a show
    /// has no single director, so `created_by` is the credit that answers the
    /// same question (the panel labels it accordingly).
    var directors: [CastMember] = []

    static let empty = TitleCredits()
    var isEmpty: Bool { cast.isEmpty && directors.isEmpty }
}

/// The single source of cast strips across the app. Replaces the three
/// near-identical fetchers that used to live in `DetailView` (movie + series)
/// and `SearchAddPanel`. Caching and coalescing are the resource store's: the
/// credits reads are archival there.
///
/// Movies come from Radarr's `/credit` when we have a Radarr id (no TMDB key
/// needed), falling back to TMDB. Series have no Radarr endpoint, so they come
/// from TMDB — by the series' `tmdbId`, or resolved from its `tvdbId` via
/// `/find` when Sonarr didn't ship a tmdbId (the fix for series that showed no
/// cast at all).
enum CastProvider {

    // MARK: - Public API

    /// Movie cast + directors. `radarrMovieId` takes Radarr's `/credit` path
    /// (works with no TMDB key, and in demo); `tmdbId` is the fallback / the
    /// only route when the caller has no Radarr id (e.g. a TMDB-sourced add-panel
    /// result).
    static func movieCredits(radarrMovieId: Int?, tmdbId: Int?, configStore: ConfigStore) async -> TitleCredits {
        return await fetchMovieCredits(radarrMovieId: radarrMovieId, tmdbId: tmdbId, configStore: configStore)
    }

    /// Series cast + creators. `tmdbId` is tried first; when absent, `tvdbId`
    /// is resolved to a tmdb id via TMDB `/find`.
    /// fixtures.
    static func seriesCredits(tmdbId: Int?, tvdbId: Int?, configStore: ConfigStore) async -> TitleCredits {
        return await fetchSeriesCredits(tmdbId: tmdbId, tvdbId: tvdbId, configStore: configStore)
    }

    // MARK: - Fetchers (the logic the three call sites used to duplicate)

    private static func fetchMovieCredits(radarrMovieId: Int?, tmdbId: Int?, configStore: ConfigStore) async -> TitleCredits {
        // Radarr `/credit` first — it needs no TMDB key and serves demo. Only
        // usable when the caller has a Radarr movie id (the detail view does;
        // a TMDB-search add-panel result does not).
        if let radarrMovieId, configStore.radarr.isConfigured {
            let credits = (try? await RadarrClient(config: configStore.radarr).fetchCredits(movieId: radarrMovieId)) ?? []
            let members = TitleCredits(cast: CastMember.from(radarrCredits: credits),
                                       directors: CastMember.directors(radarrCredits: credits))
            if !members.isEmpty { return members }
            // Radarr frequently has no credits for unreleased movies — fall
            // through to TMDB when we can.
        }
        let key = configStore.tmdbApiKey
        guard !key.isEmpty, let tmdbId, tmdbId > 0,
              let credits = try? await TMDBClient(apiKey: key).movieCredits(movieId: tmdbId)
        else { return .empty }
        return TitleCredits(cast: CastMember.from(tmdbCast: credits.cast),
                            directors: CastMember.directors(tmdbCrew: credits.crew))
    }

    private static func fetchSeriesCredits(tmdbId: Int?, tvdbId: Int?, configStore: ConfigStore) async -> TitleCredits {
        let key = configStore.tmdbApiKey
        guard !key.isEmpty else { return .empty }
        let client = TMDBClient(apiKey: key)
        // Prefer the tmdb id; otherwise resolve it from the tvdb id. This
        // second path is why series with no `tmdbId` from Sonarr now get cast.
        var resolvedTmdbId = tmdbId
        if resolvedTmdbId == nil || resolvedTmdbId == 0, let tvdbId, tvdbId > 0 {
            resolvedTmdbId = try? await client.tvIdFromTVDB(tvdbId)
        }
        guard let id = resolvedTmdbId, id > 0 else { return .empty }
        // Creators come from `/tv/{id}`, a second call — run it alongside the
        // credits so the strip and the "Created by" line land together.
        async let creators = (try? await client.tvCreators(tvId: id)) ?? []
        guard let credits = try? await client.tvCredits(tvId: id) else { return .empty }
        return TitleCredits(cast: CastMember.from(tmdbCast: credits.cast),
                            directors: CastMember.from(tmdbCreators: await creators))
    }
}
