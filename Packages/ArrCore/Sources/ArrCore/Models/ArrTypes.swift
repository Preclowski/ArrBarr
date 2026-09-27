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
    /// Resolves a poster URL from an Arr images array.
    /// Prefers `remoteUrl` (TMDB / MusicBrainz / etc., no auth) over the local server URL.
    /// - Parameter baseURL: The arr server base URL (used when only a local path is available).
    /// - Parameter coverTypes: Cover type names to match, in priority order (default: `["poster"]`).
    /// - Returns: the URL plus whether it requires the X-Api-Key header.
    /// As `posterURL(baseURL:coverTypes:)`, but preferring the connected media
    /// server's artwork when it holds this title.
    ///
    /// The override lives here rather than at the view because `RemotePoster`
    /// only ever receives a URL — it has no idea *which* title it is drawing,
    /// so it cannot do the lookup. Callers that know the title's provider ids
    /// pass them in; everyone else keeps calling the two-argument version and
    /// nothing changes.
    ///
    /// A media-server poster carries its token in the query string, so the
    /// returned "requires auth" flag is false: `PosterStore` fetches it with no
    /// arr headers at all.
    func posterURL(baseURL: String, coverTypes: [String] = ["poster"],
                   mediaServerKeys: [MediaServerExternalKey]) -> (URL?, Bool) {
        let arr = posterURL(baseURL: baseURL, coverTypes: coverTypes)
        guard let override = MediaServerIndex.shared.posterURL(for: mediaServerKeys) else { return arr }
        PosterStore.supersede(arr.0, with: override)
        return (override, false)
    }

    func posterURL(baseURL: String, coverTypes: [String] = ["poster"]) -> (URL?, Bool) {
        let normalized = coverTypes.map { $0.lowercased() }
        let match = first { img in
            guard let type = img.coverType?.lowercased() else { return false }
            return normalized.contains(type)
        }
        guard let match else { return (nil, false) }

        // Only trust remoteUrl when it's a real absolute web URL. Lidarr
        // artist records ship relative junk here ("/config/MediaCover/…" —
        // the server's own container path), which URL(string:) happily
        // accepts as a scheme-less URL that can never load. Anything
        // relative falls through to the `url` leg below, which resolves
        // against the arr's base URL.
        if let remote = match.remoteUrl, let url = URL(string: remote),
           url.scheme == "http" || url.scheme == "https" {
            return (url, false)
        }
        if let path = match.url, let base = URL(string: baseURL) {
            // Some Arrs return absolute, some relative. Strip query (cache-busting hash) for stable cache keys.
            if let abs = URL(string: path), abs.scheme != nil {
                return (abs, true)
            }
            let trimmed = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
            let composed = URL(string: trimmed, relativeTo: base)?.absoluteURL
            return (composed, true)
        }
        return (nil, false)
    }
}

