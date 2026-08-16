import Foundation

// MARK: - Shared Radarr/Sonarr v3 types
public struct ArrQueuePage<Record: Decodable>: Decodable {
    let page: Int
    let pageSize: Int
    let totalRecords: Int
    let records: [Record]
}

public struct ArrCustomFormat: Decodable, Equatable, Sendable {
    // `id` is optional because some arr endpoints (notably Radarr's
    // movie detail when CFs are referenced rather than embedded) ship
    // the format with a name but no id. A required `id` made the
    // whole `[ArrCustomFormat]` array fail decoding silently —
    // upstream that surfaces as "no chips visible in detail view"
    // even when the API has populated the list.
    let id: Int?
    let name: String
}

/// Full custom-format payload from `/api/v3/customformat` — carries the
/// matching `specifications` (the conditions that make a release match
/// this format) on top of the bare id/name in `ArrCustomFormat`. Used by
/// the chat `describe_format` tool to explain what a format actually does.
public struct ArrCustomFormatDetail: Decodable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let specifications: [Specification]?

    public struct Specification: Decodable, Equatable, Sendable {
        let name: String?
        /// Raw implementation key, e.g. "ReleaseTitleSpecification".
        let implementation: String?
        /// Human label, e.g. "Release Title". Falls back to `implementation`.
        let implementationName: String?
        let negate: Bool?
        let required: Bool?
        let fields: [Field]?
    }

    public struct Field: Decodable, Equatable, Sendable {
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
public struct ArrQualityProfile: Decodable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let formatItems: [FormatItem]?

    public struct FormatItem: Decodable, Equatable, Sendable {
        let format: Int
        let name: String?
        let score: Int
    }
}

/// One entry from Radarr's `/api/v3/credit?movieId=` endpoint — Radarr DOES
/// store cast/crew (sourced from TMDB on its side), so movie cast needs no
/// app-side TMDB key. Sonarr has no equivalent endpoint, so series cast still
/// comes from TMDB.
public struct ArrCredit: Decodable, Equatable, Sendable {
    let personName: String?
    let personTmdbId: Int?
    let character: String?
    let order: Int?
    /// "cast" or "crew".
    let type: String?
    let images: [Image]?

    public struct Image: Decodable, Equatable, Sendable {
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

public struct ArrQuality: Decodable {
    let quality: ArrQualityName?
    struct ArrQualityName: Decodable { let name: String? }
    var name: String? { quality?.name }
}

public struct ArrImage: Decodable, Equatable, Sendable {
    let coverType: String?
    let url: String?
    let remoteUrl: String?
}

/// Sonarr / Radarr / Lidarr / Whisparr all return queue warnings in
/// the same shape: an array of objects, each with a one-line `title`
/// summary (e.g. "Title mismatch") and a deeper `messages` list. We
/// flatten both into a single user-facing string per entry when the
/// status is `warning` / `failed`. No tracker-prefix or i18n parsing —
/// the arr ships these in the user's configured server locale.
public struct ArrStatusMessage: Decodable, Sendable, Equatable {
    public let title: String?
    public let messages: [String]?
}

public extension Optional where Wrapped == [ArrStatusMessage] {
    /// Flatten the arr's nested status payload into one user-facing
    /// line per actual message. We unfold each (title, [messages])
    /// entry: when there are messages we join them with " — title:",
    /// when there aren't we just take the title verbatim. Both forms
    /// show up in the wild — Sonarr emits title-only entries for
    /// "Title mismatch" and full message lists for "No files found".
    /// Whitespace-only / empty strings dropped so the caller can just
    /// check `isEmpty`.
    func flattenToLines() -> [String] {
        guard let self else { return [] }
        var out: [String] = []
        for entry in self {
            let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let messages = (entry.messages ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if messages.isEmpty {
                if let t = title, !t.isEmpty { out.append(t) }
            } else {
                let prefix = (title?.isEmpty == false) ? "\(title!): " : ""
                for m in messages { out.append(prefix + m) }
            }
        }
        return out
    }
}

// MARK: - Radarr

public struct RadarrQueueRecord: Decodable {
    let id: Int
    let movieId: Int?
    let title: String?
    let status: String?
    let trackedDownloadStatus: String?
    let trackedDownloadState: String?
    let downloadId: String?
    let downloadClient: String?
    let indexer: String?
    let `protocol`: String?
    let size: Double?
    let sizeleft: Double?
    let timeleft: String?
    let estimatedCompletionTime: String?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let movie: RadarrMovie?
    let statusMessages: [ArrStatusMessage]?
}

public struct RadarrMovie: Decodable {
    let id: Int
    let title: String
    let year: Int?
    /// TMDB id — the media server's join key. See `SonarrSeries.tvdbId`.
    var tmdbId: Int? = nil
    let originalTitle: String?
    let hasFile: Bool?
    let titleSlug: String?
    let images: [ArrImage]?
    let movieFile: ArrFile?
}

public struct ArrFile: Decodable {
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let size: Int64?
    let relativePath: String?
    /// Library tooltip extras — lazily fetched via `/moviefile?movieId=`.
    var releaseGroup: String? = nil
    var languages: [ArrFileLanguage]? = nil
}

public struct ArrFileLanguage: Decodable {
    let name: String?
}

public struct RadarrMovieFile: Decodable {
    let id: Int
    let movieId: Int?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let size: Int64?
    let relativePath: String?
}

// MARK: - Sonarr

public struct SonarrQueueRecord: Decodable {
    let id: Int
    let seriesId: Int?
    let episodeId: Int?
    let seasonNumber: Int?
    let title: String?
    let status: String?
    let trackedDownloadStatus: String?
    let trackedDownloadState: String?
    let downloadId: String?
    let downloadClient: String?
    let indexer: String?
    let `protocol`: String?
    let size: Double?
    let sizeleft: Double?
    let timeleft: String?
    let estimatedCompletionTime: String?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let series: SonarrSeries?
    let episode: SonarrEpisode?
    let statusMessages: [ArrStatusMessage]?
}

public struct SonarrSeries: Decodable {
    let id: Int
    let title: String
    let year: Int?
    /// TVDB id — how the media server's series entries are matched. Always on
    /// the wire (Sonarr keys on TVDB); newly decoded. `var … = nil` so demo
    /// mocks' memberwise inits keep compiling.
    var tvdbId: Int? = nil
    let titleSlug: String?
    let images: [ArrImage]?
    // Calendar fetches the series with `includeSeries=true`, so both of
    // these are populated when the upstream record came from /calendar.
    // SonarrLookupRatings just wraps a `value: Double?` — reuse it.
    let runtime: Int?
    let ratings: SonarrLookupRatings?
    /// Library-tooltip parity for the Upcoming tooltip.
    var genres: [String]? = nil
    var status: String? = nil
    var qualityProfileId: Int? = nil
}

public struct SonarrEpisode: Decodable {
    let id: Int
    let seasonNumber: Int?
    let episodeNumber: Int?
    let title: String?
    let hasFile: Bool?
    let episodeFileId: Int?
}

public struct SonarrEpisodeFile: Decodable {
    let id: Int
    let seriesId: Int?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let size: Int64?
    let relativePath: String?
}

// MARK: - Lidarr

public struct LidarrQueueRecord: Decodable {
    let id: Int
    let artistId: Int?
    let albumId: Int?
    let title: String?
    let status: String?
    let trackedDownloadStatus: String?
    let trackedDownloadState: String?
    let downloadId: String?
    let downloadClient: String?
    let indexer: String?
    let `protocol`: String?
    let size: Double?
    let sizeleft: Double?
    let timeleft: String?
    let estimatedCompletionTime: String?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let artist: LidarrArtist?
    let album: LidarrAlbum?
    let statusMessages: [ArrStatusMessage]?
}

public struct LidarrArtist: Decodable {
    let id: Int
    let artistName: String
    let foreignArtistId: String?
    let images: [ArrImage]?
}

public struct LidarrAlbum: Decodable {
    let id: Int
    let title: String
    let releaseDate: String?
    let foreignAlbumId: String?
    let artist: LidarrArtist?
    let images: [ArrImage]?
}

/// One on-disk track file (`/api/v1/trackfile?albumId=N`). Lidarr's queue is
/// per-album, so an album upgrade replaces N of these — the client aggregates
/// them into the album-level existing-file diff fields (quality / size / score
/// / formats). Only the fields the diff needs are decoded; extra JSON is
/// ignored.
public struct LidarrTrackFile: Decodable {
    let id: Int
    let albumId: Int?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let size: Int64?
    /// Absolute on-disk path (Lidarr sends no relativePath here) — the
    /// banner shows just the last component.
    let path: String?
}

public struct LidarrCalendarRecord: Decodable {
    let id: Int
    let title: String
    let releaseDate: String?
    let foreignAlbumId: String?
    let overview: String?
    let artist: LidarrArtist?
    let images: [ArrImage]?
    /// Albums have no `hasFile` bool — ownership is derived from the
    /// track/file tallies (same shape the library endpoint ships).
    var statistics: LidarrLibraryStatistics? = nil
}

// MARK: - History

public struct RadarrHistoryRecord: Decodable {
    let id: Int
    let movieId: Int?
    let sourceTitle: String?
    let date: String?
    let eventType: String?
    let quality: ArrQuality?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let movie: RadarrMovie?
}

public struct SonarrHistoryRecord: Decodable {
    let id: Int
    let episodeId: Int?
    let seriesId: Int?
    let sourceTitle: String?
    let downloadId: String?
    let date: String?
    let eventType: String?
    let quality: ArrQuality?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let series: SonarrSeries?
    let episode: SonarrEpisode?
}

public struct LidarrHistoryRecord: Decodable {
    let id: Int
    let albumId: Int?
    let artistId: Int?
    let sourceTitle: String?
    let downloadId: String?
    let date: String?
    let eventType: String?
    let quality: ArrQuality?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let artist: LidarrArtist?
    let album: LidarrAlbum?
}

// MARK: - Health

public struct ArrHealthRecord: Decodable, Equatable {
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
public struct ArrCommand: Decodable, Equatable {
    let name: String?
    let status: String?
    let body: Body?

    /// The command's payload. Every arr spells its record ids differently
    /// (Radarr `movieIds`, Lidarr `albumIds`, singular variants on some
    /// versions), so all the plausible spellings are decoded and any hit
    /// counts — cheaper and more version-proof than branching per product.
    struct Body: Decodable, Equatable {
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

public struct RadarrCalendarRecord: Decodable {
    let id: Int
    let title: String
    let year: Int?
    let digitalRelease: String?
    let physicalRelease: String?
    let inCinemas: String?
    let hasFile: Bool?
    let overview: String?
    let images: [ArrImage]?
    let titleSlug: String?
    // Same fields the search lookup decoder already extracts — calendar
    // returns identical movie records, just filtered by release window.
    let runtime: Int?
    let ratings: RadarrLookupRatings?
    /// Library-tooltip parity for the Upcoming tooltip: the calendar record
    /// IS a full movie resource — decode the same title facts.
    var genres: [String]? = nil
    var certification: String? = nil
    var status: String? = nil
    var qualityProfileId: Int? = nil
    /// TMDB id — the media server's join key for movies. See
    /// `SonarrSeries.tvdbId` for why this is a `var` with a default.
    var tmdbId: Int? = nil
}

public struct SonarrCalendarRecord: Decodable {
    let id: Int
    let seriesId: Int?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let title: String?
    let airDateUtc: String?
    let hasFile: Bool?
    let overview: String?
    let series: SonarrSeries?
    /// On-disk file id when `hasFile` — the Upcoming tooltip's route to the
    /// episode's file details.
    var episodeFileId: Int? = nil
}

// MARK: - Search Lookup

public struct RadarrLookupRecord: Decodable {
    /// Radarr's `/movie/lookup` echoes the library record id here for movies the
    /// user already owns (0 / absent otherwise) — the signal that drives the
    /// "in library" state on search cards.
    let id: Int?
    let tmdbId: Int?
    /// `"ttNNNNNNN"`. Needed to resolve an `imdb:ttN` search — the unified
    /// `SearchResult` identity is TMDB-keyed, so without this an IMDB ref
    /// has nothing to match against and every row gets filtered out.
    var imdbId: String? = nil
    let title: String
    let year: Int?
    let overview: String?
    let runtime: Int?
    let ratings: RadarrLookupRatings?
    let images: [ArrImage]?
    let genres: [String]?
    let certification: String?
    let studio: String?
    let status: String?
}

public struct RadarrLookupRatings: Decodable, Sendable, Equatable {
    let tmdb: RadarrLookupRatingValue?
    let imdb: RadarrLookupRatingValue?
    let metacritic: RadarrLookupRatingValue?
    let rottenTomatoes: RadarrLookupRatingValue?
}
public struct RadarrLookupRatingValue: Decodable, Sendable, Equatable {
    let value: Double?
    /// Radarr's lookup endpoint returns the same Ratings sub-object as
    /// the detail endpoint, including TMDB's vote_count. Used as the
    /// confidence weight in `SearchRelevance.bayesianQuality` so
    /// low-vote ratings get shrunk toward the global mean.
    let votes: Int?
}

public struct SonarrLookupRecord: Decodable {
    /// Library record id for series the user already owns (0 / absent otherwise)
    /// — drives the "in library" state on search cards.
    let id: Int?
    let tvdbId: Int?
    /// See `RadarrLookupRecord.imdbId` — Sonarr's lookup carries it too, so
    /// an `imdb:ttN` query can resolve a series as well as a movie.
    var imdbId: String? = nil
    /// TMDB series id, when SkyHook knows one. The verification gate in
    /// `SeriesIdentityResolver` reads it: a `term=tmdb:N` lookup is only
    /// trusted when the record that comes back actually carries that id
    /// (older Sonarr treats the unknown prefix as literal search text and
    /// answers with whatever the string fuzzy-matches).
    var tmdbId: Int? = nil
    let title: String
    let year: Int?
    let overview: String?
    let ratings: SonarrLookupRatings?
    let images: [ArrImage]?
    let statistics: SonarrLookupStats?
    let genres: [String]?
    let network: String?
    let runtime: Int?
    let status: String?
}

public struct SonarrLookupRatings: Decodable, Sendable, Equatable {
    let value: Double?
    /// TVDB vote count. Sonarr has always returned it; we used to drop it,
    /// which meant `bayesianQuality` never shrank a series rating and a
    /// 10.0-with-three-votes obscurity outranked a famous 8.6.
    var votes: Int? = nil
}

public struct SonarrLookupStats: Decodable {
    let seasonCount: Int?
}

// MARK: - Lidarr library / lookup types

public struct LidarrLibraryRecord: Decodable, Sendable, Equatable {
    public let id: Int?
    public let foreignArtistId: String?
    public let artistName: String?
    public let monitored: Bool?
    public let images: [ArrImage]?
    public let statistics: LidarrLibraryStatistics?
    /// See `SonarrLibraryRecord.qualityProfileId`.
    public var qualityProfileId: Int? = nil
    /// See `RadarrLibraryRecord.added`. Artists have no release date of their
    /// own — that belongs to their albums — so this is the only date sort
    /// Lidarr can offer.
    public var added: String? = nil
    /// Artist rating from Lidarr's metadata provider. Always on the wire; the
    /// Library tab's rating sort is the first thing to read it.
    public var ratings: LidarrLookupRatings? = nil
}
public struct LidarrLibraryStatistics: Decodable, Sendable, Equatable {
    public let albumCount: Int?
    public let trackCount: Int?
    public let trackFileCount: Int?
    public let sizeOnDisk: Int64?
}

public struct LidarrLookupRecord: Decodable {
    public let foreignArtistId: String?
    public let artistName: String
    public let disambiguation: String?
    public let overview: String?
    public let images: [ArrImage]?
    public let ratings: LidarrLookupRatings?
    public let genres: [String]?
}
public struct LidarrLookupRatings: Decodable, Sendable, Equatable {
    public let value: Double?
    /// See `SonarrLookupRatings.votes` — same dropped-signal fix.
    public var votes: Int? = nil
}

/// One entry of `/api/v1/search` — Lidarr's mixed text search (what its own
/// UI queries). Each entry wraps EITHER an artist OR an album resource;
/// `/artist/lookup` and `/album/lookup` only do text search for prefixed /
/// foreign-id terms, which is why the app searches through this endpoint.
public struct LidarrSearchRecord: Decodable {
    public let foreignId: String?
    public let artist: LidarrLookupRecord?
    public let album: LidarrAlbumLookupRecord?
}

/// Album resource as returned inside `/search` entries (and by
/// `/album/lookup` for foreign-id terms). `id` is non-zero when the album
/// is already in the library (same convention as the other arr lookups);
/// the embedded `artist` carries what the add flow needs to create the
/// artist alongside the album.
public struct LidarrAlbumLookupRecord: Decodable {
    public let id: Int?
    public let foreignAlbumId: String?
    public let title: String
    public let disambiguation: String?
    public let overview: String?
    public let albumType: String?
    public let releaseDate: String?
    public let genres: [String]?
    public let images: [ArrImage]?
    public let ratings: LidarrLookupRatings?
    public let artist: LidarrAlbumLookupArtist?
}

/// Artist as embedded in `/search` album entries. NOT `LidarrArtist` — that
/// type requires `id`, and the search payload omits it for artists that
/// aren't in the library (which is most of them), so reusing it made the
/// whole `/search` array fail to decode and music search came back empty.
public struct LidarrAlbumLookupArtist: Decodable {
    public let id: Int?
    public let artistName: String?
    public let foreignArtistId: String?
}

public struct MetadataProfile: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
}

/// Minimal movie-file projection for library records — just the quality
/// name. The full `RadarrMovieFile` isn't Sendable/Equatable and the
/// library surfaces need nothing else from it.
public struct ArrLibraryFile: Decodable, Sendable, Equatable {
    public struct Quality: Decodable, Sendable, Equatable {
        public struct Name: Decodable, Sendable, Equatable { let name: String? }
        let quality: Name?
    }
    let quality: Quality?
    var customFormats: [ArrCustomFormat]? = nil
    var customFormatScore: Int? = nil
    var relativePath: String? = nil
    var qualityName: String? { quality?.quality?.name }
}

/// One entry of an arr's alternate-title list — the translated, regional and
/// scene names a title is also known by ("Leon zawodowiec" for "Léon: The
/// Professional"). Radarr sources them from TMDB; Sonarr's are TVDB/XEM
/// aliases, so its coverage is thinner.
///
/// Shared by the inline `alternateTitles[]` on a library record and by
/// Radarr's dedicated `/alttitle` table, which is why `movieId` is here at
/// all: inline it's redundant, standalone it's the only join key.
public struct ArrAlternateTitle: Decodable, Sendable, Equatable {
    public let title: String?
    public var movieId: Int? = nil

    public init(title: String?, movieId: Int? = nil) {
        self.title = title
        self.movieId = movieId
    }
}

// Used to fetch existing library ids and list library contents
public struct RadarrLibraryRecord: Decodable, Sendable, Equatable {
    let id: Int?
    let tmdbId: Int?
    let title: String?
    let year: Int?
    let hasFile: Bool?
    /// Deep-link slug for the arr web UI. Always been on the wire; decoding it
    /// costs nothing and lets the Spotlight pass seed `TitleMetadataStore`
    /// completely, so the queue never has to fetch a movie just for its slug.
    let titleSlug: String?
    let monitored: Bool?
    let images: [ArrImage]?
    let genres: [String]?
    let runtime: Int?
    let overview: String?
    let ratings: RadarrLookupRatings?
    let certification: String?
    let studio: String?
    let sizeOnDisk: Int64?
    /// Radarr availability ("announced" / "inCinemas" / "released") — the
    /// Library tooltip's release-status row.
    var status: String? = nil
    /// Radarr's computed "can this be grabbed yet" flag (minimumAvailability
    /// vs release state) — splits Missing into Missing / Not available.
    var isAvailable: Bool? = nil
    /// Library tab: the on-disk file's actual quality ("WEBDL-1080p").
    /// Present in `/api/v3/movie` whenever `hasFile` — we just never
    /// decoded it before.
    var movieFile: ArrLibraryFile? = nil
    /// Library tab fallback when there's no file yet — resolved to the
    /// profile's name via `/qualityprofile`. (`var … = nil` so the demo
    /// mocks' memberwise inits keep compiling; Decodable still decodes it.)
    var qualityProfileId: Int? = nil
    /// The title in its own language ("Nuovo Cinema Paradiso"). Always on the
    /// wire; feeding the library filter is the first thing that wanted it.
    var originalTitle: String? = nil
    /// When the movie was added to Radarr — the Library tab's "Date added"
    /// sort. ISO 8601 on the wire, parsed at unify time.
    var added: String? = nil
    /// Radarr's three release dates. The Library tab sorts on the earliest
    /// one that exists: a film is "released" the day it first reached anyone,
    /// and only the physical date is guaranteed absent for streaming titles.
    var inCinemas: String? = nil
    var digitalRelease: String? = nil
    var physicalRelease: String? = nil
    /// Translated / regional names. Whether `/api/v3/movie` inlines these
    /// varies by Radarr version — `RadarrClient.alternateTitleMap` falls back
    /// to the `/alttitle` table when it doesn't.
    var alternateTitles: [ArrAlternateTitle]? = nil
}
public struct SonarrLibraryRecord: Decodable, Sendable, Equatable {
    let id: Int?
    let tvdbId: Int?
    let title: String?
    let year: Int?
    let status: String?
    let monitored: Bool?
    let statistics: SonarrLibraryStatistics?
    let images: [ArrImage]?
    /// Per-season state. Populated by `/api/v3/series` when we ask for it
    /// — the field has always been in the JSON, we just didn't decode it.
    /// Lets `sonarr_get_series` answer "is S3 monitored?" without a
    /// second round-trip to the series detail endpoint.
    let seasons: [SonarrLibrarySeason]?
    let overview: String?
    /// See `RadarrLibraryRecord.titleSlug` — same field, same reason.
    let titleSlug: String?
    /// Series have no single file quality — the Library tab shows the
    /// assigned profile's name instead. (`var … = nil`: see RadarrLibraryRecord.)
    var qualityProfileId: Int? = nil
    /// TVDB rating — feeds the Library tab's rating sort.
    var ratings: SonarrLookupRatings? = nil
    /// Library tooltip garnish — always on the wire, newly decoded.
    var genres: [String]? = nil
    /// TMDB's own series id. Sonarr v3+ ships it on `/api/v3/series` (same
    /// field `SonarrSeries` already decodes); we simply never read it here.
    /// It is what lets a TMDB-sourced row be matched against the library by
    /// *id* — before this, TMDB series could only be joined on title + year,
    /// which is how a same-titled show got mistaken for one you own.
    var tmdbId: Int? = nil
    /// Aliases from TVDB / TheXEM. Sonarr always inlines these on
    /// `/api/v3/series` (see the payload note in `SonarrClient.fetchQueue`),
    /// so unlike Radarr there's no fallback endpoint to reach for. They're
    /// scene names first and translations second, so coverage of foreign
    /// titles is thinner here than for movies.
    var alternateTitles: [ArrAlternateTitle]? = nil
    /// See `RadarrLibraryRecord.added`.
    var added: String? = nil
    /// First episode's air date — a series' equivalent of a release date.
    var firstAired: String? = nil
}
public struct SonarrLibraryStatistics: Decodable, Sendable, Equatable {
    let episodeCount: Int?
    let episodeFileCount: Int?
    let seasonCount: Int?
    let sizeOnDisk: Int64?
}
public struct SonarrLibrarySeason: Decodable, Sendable, Equatable {
    let seasonNumber: Int
    let monitored: Bool?
    let statistics: SonarrLibrarySeasonStatistics?
}
public struct SonarrLibrarySeasonStatistics: Decodable, Sendable, Equatable {
    let episodeCount: Int?
    let episodeFileCount: Int?
    let totalEpisodeCount: Int?
}

// MARK: - Whisparr

public struct WhisparrQueueRecord: Decodable {
    let id: Int
    let movieId: Int?
    let title: String?
    let status: String?
    let trackedDownloadStatus: String?
    let trackedDownloadState: String?
    let downloadId: String?
    let downloadClient: String?
    let indexer: String?
    let `protocol`: String?
    let size: Double?
    let sizeleft: Double?
    let timeleft: String?
    let estimatedCompletionTime: String?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let quality: ArrQuality?
    let movie: WhisparrMovie?
    let statusMessages: [ArrStatusMessage]?
}

public struct WhisparrMovie: Decodable {
    let id: Int
    let title: String
    let year: Int?
    let studio: String?
    let hasFile: Bool?
    let titleSlug: String?
    let images: [ArrImage]?
    let movieFile: ArrFile?
}

public struct WhisparrCalendarRecord: Decodable {
    let id: Int
    let title: String
    let year: Int?
    let digitalRelease: String?
    let physicalRelease: String?
    let inCinemas: String?
    let hasFile: Bool?
    let overview: String?
    let images: [ArrImage]?
    let titleSlug: String?
    let studio: String?
    // Whisparr is a Radarr fork and returns the same shape for scenes.
    let runtime: Int?
    let ratings: RadarrLookupRatings?
    var genres: [String]? = nil
    var status: String? = nil
    var qualityProfileId: Int? = nil
}

public struct WhisparrHistoryRecord: Decodable {
    let id: Int
    let movieId: Int?
    let sourceTitle: String?
    let date: String?
    let eventType: String?
    let quality: ArrQuality?
    let customFormats: [ArrCustomFormat]?
    let customFormatScore: Int?
    let movie: WhisparrMovie?
}

public struct WhisparrLibraryRecord: Decodable, Sendable, Equatable {
    public let id: Int?
    public let foreignId: String?
    public let tmdbId: Int?
    public let title: String?
    public let year: Int?
    public let studio: String?
    public let hasFile: Bool?
    public let monitored: Bool?
    public let images: [ArrImage]?
    public let sizeOnDisk: Int64?
    /// See `RadarrLibraryRecord.movieFile` / `qualityProfileId` / `status`.
    public var movieFile: ArrLibraryFile? = nil
    public var qualityProfileId: Int? = nil
    public var status: String? = nil
    public var isAvailable: Bool? = nil
    /// See `RadarrLibraryRecord.added`.
    public var added: String? = nil
}

public struct WhisparrLookupRecord: Decodable {
    public let foreignId: String?
    public let tmdbId: Int?
    public let title: String
    public let year: Int?
    public let overview: String?
    public let runtime: Int?
    public let studio: String?
    public let images: [ArrImage]?
    public let genres: [String]?
    public let ratings: RadarrLookupRatings?
}

// MARK: - ArrImage helpers

public extension Array where Element == ArrImage {
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
        if let override = MediaServerIndex.shared.posterURL(for: mediaServerKeys) {
            return (override, false)
        }
        return posterURL(baseURL: baseURL, coverTypes: coverTypes)
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
