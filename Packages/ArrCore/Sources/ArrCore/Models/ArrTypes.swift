import Foundation
import MediaKit

// MARK: - Shared Radarr/Sonarr v3 types
/// Full custom-format payload from `/api/v3/customformat` — carries the
/// matching `specifications` (the conditions that make a release match
/// this format) on top of the bare id/name in `ArrCustomFormat`. Used by
/// the chat `describe_format` tool to explain what a format actually does.
nonisolated public struct ArrCustomFormatDetail: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let specifications: [Specification]?

    nonisolated public struct Specification: Codable, Equatable, Sendable {
        let name: String?
        /// Raw implementation key, e.g. "ReleaseTitleSpecification".
        let implementation: String?
        /// Human label, e.g. "Release Title". Falls back to `implementation`.
        let implementationName: String?
        let negate: Bool?
        let required: Bool?
        let fields: [Field]?
    }

    nonisolated public struct Field: Codable, Equatable, Sendable {
        let name: String?
        /// Polymorphic — a regex string, an enum int, an array of ints, …
        /// Kept as `JSONValue` so the describe tool can stringify whatever
        /// the spec carries without a per-implementation schema.
        let value: JSONValue?
    }
}

/// Quality profile from `/api/v3/qualityprofile`. We only decode the bits
/// the `describe_format` tool needs: the per-format score table so we can
/// report "this format scores +50 in profile HD-1080p".
nonisolated public struct ArrQualityProfile: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let formatItems: [FormatItem]?

    nonisolated public struct FormatItem: Codable, Equatable, Sendable {
        let format: Int
        let name: String?
        let score: Int
    }
}

/// One entry from Radarr's `/api/v3/credit?movieId=` endpoint — Radarr DOES
/// store cast/crew (sourced from TMDB on its side), so movie cast needs no
/// app-side TMDB key. Sonarr has no equivalent endpoint, so series cast still
/// comes from TMDB.
nonisolated public struct ArrCredit: Codable, Equatable, Sendable {
    let personName: String?
    let personTmdbId: Int?
    let character: String?
    let order: Int?
    /// "cast" or "crew".
    let type: String?
    /// Crew credits only — the department ("Directing", "Writing", …).
    let department: String?
    /// Crew credits only — the job ("Director", "Screenplay", …).
    let job: String?
    let images: [Image]?

    nonisolated public struct Image: Codable, Equatable, Sendable {
        let coverType: String?
        /// Local Radarr proxy path (needs api key). Prefer `remoteUrl`.
        let url: String?
        /// Absolute TMDB image URL — usable without auth.
        let remoteUrl: String?
    }

    /// Headshot URL for display — the TMDB `remoteUrl` (no auth) of the
    /// headshot cover, falling back to any image's remoteUrl.
    var headshotURL: URL? {
        let pick = images?.first { ($0.coverType ?? "").lowercased() == "headshot" } ?? images?.first
        return pick?.remoteUrl.flatMap(URL.init(string:))
    }
}

// MARK: - Radarr



// MARK: - Sonarr




// MARK: - Lidarr


// MARK: - Health

nonisolated public struct ArrHealthRecord: Codable, Equatable, Sendable {
    let source: String?
    let type: String?
    let message: String?
    let wikiUrl: String?
}

// MARK: - Commands

/// One entry from `GET /command` — the server's own view of what it is busy
/// with. We only care about indexer searches: whether one is in flight for a
/// given record is otherwise unknowable client-side, because `POST /command`
/// is fire-and-forget here and `addOptions.searchForMovie` fires entirely
/// server-side, where the app never sees a command id at all.
nonisolated public struct ArrCommand: Codable, Equatable, Sendable {
    let name: String?
    let status: String?
    let body: Body?

    /// The command's payload. Every arr spells its record ids differently
    /// (Radarr `movieIds`, Lidarr `albumIds`, singular variants on some
    /// versions), so all the plausible spellings are decoded and any hit
    /// counts — cheaper and more version-proof than branching per product.
    nonisolated struct Body: Codable, Equatable, Sendable {
        let movieIds: [Int]?
        let movieId: Int?
        let albumIds: [Int]?
        let albumId: Int?
    }

    /// `queued` and `started` both mean "not finished". Anything else
    /// (completed / failed / aborted) is over.
    var isRunning: Bool {
        guard let status = status?.lowercased() else { return false }
        return status == "queued" || status == "started"
    }

    /// Matched on the name *containing* "search" rather than an exact list —
    /// the add-triggered search, the CTA search and their per-product names
    /// (`MoviesSearch`, `AlbumSearch`, …) all share that substring, and a new
    /// arr release coining another one shouldn't silently stop matching.
    func isSearch(for entityId: Int) -> Bool {
        guard isRunning, name?.lowercased().contains("search") == true else { return false }
        guard let body else { return false }
        return body.movieIds?.contains(entityId) == true
            || body.movieId == entityId
            || body.albumIds?.contains(entityId) == true
            || body.albumId == entityId
    }
}

// MARK: - Calendar



// MARK: - Search Lookup

// MARK: - Lidarr library / lookup types

nonisolated public struct MetadataProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
}


// MARK: - Whisparr





// MARK: - ArrImage helpers

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

