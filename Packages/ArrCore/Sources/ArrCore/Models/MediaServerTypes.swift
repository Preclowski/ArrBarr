import Foundation

/// What kind of thing a media-server library entry is. Deliberately coarse:
/// ArrBarr only ever needs to line an entry up against a Radarr movie or a
/// Sonarr series, so seasons, episodes and tracks collapse into their parent
/// or are dropped.
public enum MediaServerItemKind: String, Sendable, Equatable {
    case movie, show
}

/// An external metadata id a title can be matched by. Titles and years are a
/// last resort (remakes, localized titles, "The" prefixes) — every one of the
/// three servers stores provider ids, and so do the arrs, so the join is done
/// on ids alone.
public enum MediaServerExternalKey: Hashable, Sendable {
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
public struct MediaServerEntry: Sendable, Equatable {
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
public struct MediaServerSession: Sendable, Equatable {
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
public struct MediaServerWatch: Sendable, Equatable {
    public let title: String
    public let year: Int?
    public let kind: MediaServerItemKind
    public let watchedAt: Date?

    public init(title: String, year: Int?, kind: MediaServerItemKind, watchedAt: Date?) {
        self.title = title
        self.year = year
        self.kind = kind
        self.watchedAt = watchedAt
    }
}

/// Outcome of a successful connection test: what to show the user, plus the
/// user id the client resolved on their behalf (Jellyfin / Emby only).
public struct MediaServerHandshake: Sendable, Equatable {
    /// e.g. "Plex 1.40.2" — shown verbatim in Settings.
    public let versionLine: String
    /// Non-nil when the server scopes play state per user and one was found.
    public let userId: String?

    public init(versionLine: String, userId: String?) {
        self.versionLine = versionLine
        self.userId = userId
    }
}

public enum MediaServerError: LocalizedError {
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
