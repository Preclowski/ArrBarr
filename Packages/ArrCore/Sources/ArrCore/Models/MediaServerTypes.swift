import Foundation
import MediaKit

/// Deliberately coarse: entries only line up against Radarr movies or Sonarr series.
nonisolated public enum MediaServerItemKind: String, Sendable, Equatable {
    case movie, show
}

/// The join is on ids alone; titles and years are unreliable. TMDB numbers movies and series separately,
/// so its id carries the kind.
nonisolated public enum MediaServerExternalKey: Hashable, Sendable {
    case tmdbMovie(Int)
    case tmdbSeries(Int)
    case tvdb(Int)
    case imdb(String)
}

/// Deliberately narrow: the app only asks "which artwork?" and "seen it?", and unread fields go stale.
nonisolated public struct MediaServerEntry: Sendable, Equatable {
    /// `ratingKey` on Plex, `Id` on Jellyfin/Emby. Distinct titles are counted by it, since one title has several index keys.
    public let itemId: String
    /// Token-free: the credential is a header reference `PosterStore` resolves per download.
    public let poster: ArtworkReference?
    public var posterURL: URL? { poster?.url }
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

nonisolated public struct MediaServerWatch: Sendable, Equatable {
    public let title: String
    public let year: Int?
    public let kind: MediaServerItemKind
    public let watchedAt: Date?
    /// Episodes only. A series is never "watched" while airing, so tonight's episode needs its own mark.
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

/// The user id is resolved for Jellyfin / Emby only.
nonisolated public struct MediaServerHandshake: Sendable, Equatable {
    public let versionLine: String
    public let userId: String?

    public init(versionLine: String, userId: String?) {
        self.versionLine = versionLine
        self.userId = userId
    }
}

nonisolated enum MediaServerError: LocalizedError {
    case notConfigured
    /// Jellyfin and Emby delete an item when its file goes; nothing to purge.
    case trashUnsupported(server: String)
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
    var displayName: String { title.isEmpty ? key : title }
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
    var headline: String { parentTitle ?? title }
    var episodeLine: String? { parentTitle == nil ? nil : title }
}
