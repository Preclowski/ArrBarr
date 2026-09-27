import Foundation
import MediaKit

// MARK: - Shared Radarr/Sonarr v3 types
// MARK: - Radarr



// MARK: - Sonarr




// MARK: - Lidarr


// MARK: - Health

// MARK: - Commands

// MARK: - Calendar



// MARK: - Search Lookup

// MARK: - Lidarr library / lookup types

// MARK: - Whisparr





// MARK: - ArrImage helpers

nonisolated extension ArrCredit {
    var headshotURL: URL? {
        let pick = images?.first { ($0.coverType ?? "").lowercased() == "headshot" } ?? images?.first
        return pick?.remoteUrl.flatMap(URL.init(string:))
    }
}

nonisolated extension ArrCommand {
    /// A search for this movie or album still queued or running.
    func isSearch(for entityId: Int) -> Bool {
        guard isRunning, name?.lowercased().contains("search") == true, let body else { return false }
        return body.movieIds?.contains(entityId) == true || body.movieId == entityId
            || body.albumIds?.contains(entityId) == true || body.albumId == entityId
    }
}

nonisolated public extension Array where Element == ArrImage {
    /// The poster to draw and whether it needs the arr's API key. The media
    /// server's artwork wins when it holds the title (its token rides in the
    /// query, so no auth); otherwise the first image of `coverTypes`, preferring
    /// the no-auth `remoteUrl` over the arr's own copy.
    func posterURL(baseURL: String, coverTypes: [String] = ["poster"],
                   mediaServerKeys: [MediaServerExternalKey] = []) -> (URL?, Bool) {
        let arr = ownPosterURL(baseURL: baseURL, coverTypes: coverTypes)
        guard !mediaServerKeys.isEmpty, let override = MediaServerIndex.shared.posterURL(for: mediaServerKeys) else { return arr }
        PosterStore.supersede(arr.0, with: override)
        return (override, false)
    }

    private func ownPosterURL(baseURL: String, coverTypes: [String]) -> (URL?, Bool) {
        let normalized = coverTypes.map { $0.lowercased() }
        guard let match = first(where: { normalized.contains(($0.coverType ?? "").lowercased()) }) else { return (nil, false) }
        // Only an absolute web remoteUrl: Lidarr ships container paths ("/config/MediaCover/…") there.
        if let remote = match.remoteUrl, let url = URL(string: remote), url.scheme == "http" || url.scheme == "https" {
            return (url, false)
        }
        if let path = match.url, let base = URL(string: baseURL) {
            if let abs = URL(string: path), abs.scheme != nil { return (abs, true) }
            // The query is a cache-busting hash; dropping it keeps the cache key stable.
            let trimmed = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
            return (URL(string: trimmed, relativeTo: base)?.absoluteURL, true)
        }
        return (nil, false)
    }
}

nonisolated public extension ArrAlbum {
    func coverURL(baseURL: String) -> (URL?, Bool) { [ArrImage].lidarrCover(album: images, artist: artist?.images, baseURL: baseURL) }
}

nonisolated extension Array where Element == ArrImage {
    /// Lidarr's artwork: the album's cover, else its artist's poster.
    static func lidarrCover(album: [ArrImage]?, artist: [ArrImage]?, baseURL: String) -> (URL?, Bool) {
        let own = (album ?? []).posterURL(baseURL: baseURL, coverTypes: ["cover", "poster"])
        return own.0 != nil ? own : (artist ?? []).posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"])
    }
}
