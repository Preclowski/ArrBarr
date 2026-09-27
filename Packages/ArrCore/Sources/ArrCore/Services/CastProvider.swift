import Foundation
import MediaKit

/// Fetched together because both come out of the same credits payload.
struct TitleCredits: Equatable, Sendable {
    var cast: [CastMember] = []
    /// Series: the creators (`created_by`), since a show has no single director.
    var directors: [CastMember] = []

    static let empty = TitleCredits()
    var isEmpty: Bool { cast.isEmpty && directors.isEmpty }
}

/// The single source of cast strips; caching and coalescing are the resource store's.
/// Series come from TMDB, by `tmdbId` or resolved from `tvdbId` via `/find` when Sonarr has none.
enum CastProvider {

    // MARK: - Public API

    /// `radarrMovieId` takes Radarr's `/credit` (no TMDB key needed); `tmdbId` is the fallback.
    static func movieCredits(radarrMovieId: Int?, tmdbId: Int?, configStore: ConfigStore) async -> TitleCredits {
        if let radarrMovieId, configStore.radarr.isConfigured {
            let credits = (try? await configStore.radarrClient.fetchCredits(movieId: radarrMovieId)) ?? []
            let members = TitleCredits(cast: CastMember.from(radarrCredits: credits),
                                       directors: CastMember.directors(radarrCredits: credits))
            if !members.isEmpty { return members }
            // Radarr frequently has no credits for unreleased movies.
        }
        let key = configStore.tmdbApiKey
        guard !key.isEmpty, let tmdbId, tmdbId > 0,
              let credits = try? await configStore.tmdbClient.movieCredits(movieId: tmdbId)
        else { return .empty }
        return TitleCredits(cast: CastMember.from(tmdbCast: credits.cast),
                            directors: CastMember.directors(tmdbCrew: credits.crew ?? []))
    }

    /// By the series' TMDB id or its TVDB id resolved through `/find`.
    static func seriesCredits(tmdbId: Int?, tvdbId: Int?, configStore: ConfigStore) async -> TitleCredits {
        guard !configStore.tmdbApiKey.isEmpty else { return .empty }
        let client = configStore.tmdbClient
        guard let id = await client.seriesId(tmdbId: tmdbId, tvdbId: tvdbId) else { return .empty }
        // Run alongside the credits so the strip and "Created by" land together.
        async let creators = (try? await client.tvCreators(tvId: id)) ?? []
        guard let credits = try? await client.tvCredits(tvId: id) else { return .empty }
        return TitleCredits(cast: CastMember.from(tmdbCast: credits.cast),
                            directors: CastMember.from(tmdbCreators: await creators))
    }
}
