import Foundation
import MediaKit

nonisolated public struct TrailerClip: Hashable, Sendable, Identifiable {
    public let key: String
    /// TMDB's title for the clip; nil for Radarr's bare trailer id.
    public let name: String?
    public var id: String { key }

    var thumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(key)/mqdefault.jpg") }
}

nonisolated public struct TrailerReel: Hashable, Sendable {
    public let clips: [TrailerClip]

    /// `featuredKey` (Radarr's own pick) leads the reel whether or not TMDB lists it too.
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

/// Radarr's `youTubeTrailerId` leads the reel when present; the rest come from TMDB
/// `/videos` (series always — Sonarr ships no trailer field).
enum TrailerProvider {

    // MARK: - Public API

    /// Radarr sends `""` for "none"; pass it straight through.
    static func movieReel(radarrTrailerId: String?, tmdbId: Int?,
                          configStore: ConfigStore) async -> TrailerReel? {
        var clips: [TrailerClip] = []
        if let tmdbId, tmdbId > 0 {
            clips = await fetch(configStore: configStore) { try await $0.movieVideos(movieId: tmdbId) }
        }
        return TrailerReel(featuredKey: radarrTrailerId, clips: clips)
    }

    /// `tvdbId` resolves series Sonarr shipped without a `tmdbId`.
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
