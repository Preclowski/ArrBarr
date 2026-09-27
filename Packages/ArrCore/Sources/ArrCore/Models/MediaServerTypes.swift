import Foundation
import MediaKit

/// What kind of thing a media-server library entry is. Deliberately coarse:
/// ArrBarr only ever needs to line an entry up against a Radarr movie or a
/// Sonarr series, so seasons, episodes and tracks collapse into their parent
/// or are dropped.
nonisolated public enum MediaServerItemKind: String, Sendable, Equatable {
    case movie, show
}

/// An external metadata id a title can be matched by. Titles and years are a
/// last resort (remakes, localized titles, "The" prefixes) — every one of the
/// three servers stores provider ids, and so do the arrs, so the join is done
/// on ids alone. TMDB numbers movies and series separately, so its id carries the kind.
nonisolated public enum MediaServerExternalKey: Hashable, Sendable {
    case tmdbMovie(Int)
    case tmdbSeries(Int)
    case tvdb(Int)
    case imdb(String)
}

/// One title as the media server knows it.
///
/// Deliberately narrow: the server reports far more (titles, years, play
/// counts, last-played dates), but the app joins on ids and asks only two
/// questions of the answer — "which artwork?" and "seen it?". Fields nothing
/// reads would be fields nothing keeps correct.
nonisolated public struct MediaServerEntry: Sendable, Equatable {
    /// The server's own id — `ratingKey` on Plex, `Id` on Jellyfin/Emby.
    /// Distinct titles are counted by it, since one title occupies several
    /// index keys.
    public let itemId: String
    /// Token-free: the credential is a header reference `PosterStore` resolves per download.
    public let poster: ArtworkReference?
    public var posterURL: URL? { poster?.url }
    /// Every provider id this title exposes. All of them become index keys.
    public let externalKeys: [MediaServerExternalKey]
    public let watched: Bool

    public init(itemId: String, poster: ArtworkReference?,
                externalKeys: [MediaServerExternalKey], watched: Bool) {
        self.itemId = itemId
        self.poster = poster
        self.externalKeys = externalKeys
        self.watched = watched
    }
}

/// One finished play, newest first when returned in a list.
nonisolated public struct MediaServerWatch: Sendable, Equatable {
    public let title: String
    public let year: Int?
    public let kind: MediaServerItemKind
    public let watchedAt: Date?
    /// Episodes only: which series item the play belongs to, and where in it.
    /// The index turns these into the per-episode watched marks the Upcoming
    /// rows draw — a series is never "watched" while it is still airing, so
    /// the title-level flag says nothing about tonight's episode.
    public let seriesItemId: String?
    public let season: Int?
    public let episode: Int?

    public init(title: String, year: Int?, kind: MediaServerItemKind, watchedAt: Date?,
                seriesItemId: String? = nil, season: Int? = nil, episode: Int? = nil) {
        self.title = title
        self.year = year
        self.kind = kind
        self.watchedAt = watchedAt
        self.seriesItemId = seriesItemId
        self.season = season
        self.episode = episode
    }
}

/// Outcome of a successful connection test: what to show the user, plus the
/// user id the client resolved on their behalf (Jellyfin / Emby only).
nonisolated public struct MediaServerHandshake: Sendable, Equatable {
    /// e.g. "Plex 1.40.2" — shown verbatim in Settings.
    public let versionLine: String
    /// Non-nil when the server scopes play state per user and one was found.
    public let userId: String?

    public init(versionLine: String, userId: String?) {
        self.versionLine = versionLine
        self.userId = userId
    }
}

nonisolated enum MediaServerError: LocalizedError {
    case notConfigured
    /// "Empty trash" is a Plex concept — Jellyfin and Emby delete an item when
    /// its file goes, so there is nothing to purge.
    case trashUnsupported(server: String)
    /// Jellyfin / Emby need a user id for play state and none could be found.
    case noUserResolved

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Media server is not configured.", bundle: .module)
        case .trashUnsupported(let server):
            return String(localized: "\(server) has no trash to empty.", bundle: .module)
        case .noUserResolved:
            return String(localized: "Couldn't work out which user to read play state for.", bundle: .module)
        }
    }
}

nonisolated public extension MediaServerLibrary {
    /// The server's title, or its key when it has none.
    var displayName: String { title.isEmpty ? key : title }
    /// The glyph a Settings row wears for this library.
    var symbol: String {
        switch kind {
        case .movie: "film"
        case .series: "tv"
        case .artist, .album, .track: "music.note"
        default: "folder"
        }
    }
}

nonisolated public extension MediaServerSession {
    /// The show for an episode, the film otherwise.
    var headline: String { parentTitle ?? title }
    /// The episode's own title under its show; nil for a film.
    var episodeLine: String? { parentTitle == nil ? nil : title }
}
