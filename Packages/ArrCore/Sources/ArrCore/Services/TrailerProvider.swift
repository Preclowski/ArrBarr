import Foundation
import MediaKit

/// One playable YouTube clip from a title's videos.
nonisolated public struct TrailerClip: Hashable, Sendable, Identifiable {
    public let key: String
    /// TMDB's title for the clip; nil for Radarr's bare trailer id.
    public let name: String?
    public var id: String { key }

    var thumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(key)/mqdefault.jpg") }
}

/// Every clip a title has, featured one first. What the badge opens and what
/// the player's tile strip lists.
nonisolated public struct TrailerReel: Hashable, Sendable {
    public let clips: [TrailerClip]

    /// `featuredKey` (Radarr's own pick) leads the reel whether or not TMDB
    /// lists it too; nil when there is nothing to play.
    init?(featuredKey: String?, clips: [TrailerClip]) {
        var clips = clips
        if let featuredKey, !featuredKey.isEmpty {
            let existing = clips.firstIndex { $0.key == featuredKey }.map { clips.remove(at: $0) }
            clips.insert(existing ?? TrailerClip(key: featuredKey, name: nil), at: 0)
        }
        guard !clips.isEmpty else { return nil }
        self.clips = clips
    }

    var featuredKey: String { clips[0].key }
}

/// Resolves the trailers for a title, for both the detail hero's badge and the
/// Quiz's play button. Radarr's own `youTubeTrailerId` leads the reel when the
/// detail payload has one; the rest come from TMDB `/videos` (series always —
/// Sonarr ships no trailer field at all).
enum TrailerProvider {

    // MARK: - Public API

    /// `radarrTrailerId` is Radarr's own field — pass it straight through even
    /// when empty; Radarr sends `""` for "none".
    static func movieReel(radarrTrailerId: String?, tmdbId: Int?,
                          configStore: ConfigStore) async -> TrailerReel? {
        var clips: [TrailerClip] = []
        if let tmdbId, tmdbId > 0 {
            clips = await fetch(configStore: configStore) { try await $0.movieVideos(movieId: tmdbId) }
        }
        return TrailerReel(featuredKey: radarrTrailerId, clips: clips)
    }

    /// `tvdbId` is the fallback route for the series Sonarr didn't ship a
    /// `tmdbId` for — same `/find` hop the cast strip makes.
    static func seriesReel(tmdbId: Int?, tvdbId: Int?,
                           configStore: ConfigStore) async -> TrailerReel? {
        guard (tmdbId ?? 0) > 0 || (tvdbId ?? 0) > 0 else { return nil }
        let clips = await fetch(configStore: configStore) { client in
            guard let id = await client.seriesId(tmdbId: tmdbId, tvdbId: tvdbId) else { return [] }
            return try await client.tvVideos(tvId: id)
        }
        return TrailerReel(featuredKey: nil, clips: clips)
    }

    // MARK: - Fetch

    private static func fetch(configStore: ConfigStore,
                              _ videos: @escaping (TMDBClient) async throws -> [TMDBVideo]) async -> [TrailerClip] {
        guard !configStore.tmdbApiKey.isEmpty, let list = try? await videos(configStore.tmdbClient) else { return [] }
        return TMDBVideo.rankedYouTube(list).map { TrailerClip(key: $0.key, name: $0.name) }
    }
}
