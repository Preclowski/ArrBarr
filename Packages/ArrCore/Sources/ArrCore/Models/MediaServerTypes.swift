import Foundation

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
/// on ids alone.
nonisolated public enum MediaServerExternalKey: Hashable, Sendable {
    case tmdb(Int)
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
    /// Token-free, so it can be persisted and cached; see
    /// `MediaServerPosterAccess`.
    public let posterURL: URL?
    /// Every provider id this title exposes. All of them become index keys.
    public let externalKeys: [MediaServerExternalKey]
    public let watched: Bool

    public init(itemId: String, posterURL: URL?,
                externalKeys: [MediaServerExternalKey], watched: Bool) {
        self.itemId = itemId
        self.posterURL = posterURL
        self.externalKeys = externalKeys
        self.watched = watched
    }
}

/// An in-progress playback on the server.
nonisolated public struct MediaServerSession: Sendable, Equatable {
    public let title: String
    /// "Movie" / series+episode line, already assembled for display.
    public let subtitle: String?
    public let user: String?
    public let device: String?
    /// Whether the server is transcoding rather than direct-playing.
    public let isTranscoding: Bool
    /// 0…1, nil when the server didn't report a position.
    public let progress: Double?

    public init(title: String, subtitle: String?, user: String?, device: String?,
                isTranscoding: Bool, progress: Double?) {
        self.title = title
        self.subtitle = subtitle
        self.user = user
        self.device = device
        self.isTranscoding = isTranscoding
        self.progress = progress
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

/// One library on the server — a "section" on Plex, a "virtual folder" on
/// Jellyfin / Emby. The unit maintenance runs on: a rescan or a purge is
/// asked of one library, never of the whole server, so a 40 000-track music
/// section isn't rescanned because a movie just finished importing.
nonisolated public struct MediaServerLibrary: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case movies, series, music, other

        /// The glyph a Settings row wears for this library.
        public var symbol: String {
            switch self {
            case .movies: return "film"
            case .series: return "tv"
            case .music: return "music.note"
            case .other: return "folder"
            }
        }
    }

    /// The server's own key for the library — Plex's section key, Jellyfin's
    /// folder item id. Opaque; only ever handed back to the same server.
    public let id: String
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
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

nonisolated public enum MediaServerError: LocalizedError {
    case notConfigured
    /// "Empty trash" is a Plex concept — Jellyfin and Emby delete an item when
    /// its file goes, so there is nothing to purge.
    case trashUnsupported(server: String)
    /// Jellyfin / Emby need a user id for play state and none could be found.
    case noUserResolved

    public var errorDescription: String? {
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
