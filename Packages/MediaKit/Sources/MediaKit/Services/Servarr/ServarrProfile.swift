import Foundation

/// What differs between Radarr, Sonarr, Lidarr and Whisparr: nouns and query spellings, nothing else.
public struct ServarrProfile: Sendable, Hashable {
    public let kind: InstanceKind
    public let apiBase: String
    public let entityNoun: String
    public let entityKind: MediaKind
    public let fileNoun: String
    public let fileParentKey: String
    public let queueIncludeFlag: String
    public let historyIncludeKeys: [String]
    public let historyIDsKey: String
    public let calendarIncludeKey: String?

    public static let radarr = ServarrProfile(
        kind: .radarr, apiBase: "/api/v3", entityNoun: "movie", entityKind: .movie, fileNoun: "moviefile",
        fileParentKey: "movieId", queueIncludeFlag: "includeUnknownMovieItems", historyIncludeKeys: ["includeMovie"],
        historyIDsKey: "movieIds", calendarIncludeKey: nil)

    public static let sonarr = ServarrProfile(
        kind: .sonarr, apiBase: "/api/v3", entityNoun: "series", entityKind: .series, fileNoun: "episodefile",
        fileParentKey: "seriesId", queueIncludeFlag: "includeEpisode", historyIncludeKeys: ["includeSeries", "includeEpisode"],
        historyIDsKey: "seriesIds", calendarIncludeKey: "includeSeries")

    public static let lidarr = ServarrProfile(
        kind: .lidarr, apiBase: "/api/v1", entityNoun: "artist", entityKind: .artist, fileNoun: "trackfile",
        fileParentKey: "albumId", queueIncludeFlag: "includeUnknownArtistItems", historyIncludeKeys: ["includeArtist", "includeAlbum"],
        historyIDsKey: "albumId", calendarIncludeKey: "includeArtist")

    public static let whisparr = ServarrProfile(
        kind: .whisparr, apiBase: "/api/v3", entityNoun: "movie", entityKind: .movie, fileNoun: "moviefile",
        fileParentKey: "movieId", queueIncludeFlag: "includeUnknownMovieItems", historyIncludeKeys: ["includeMovie"],
        historyIDsKey: "movieIds", calendarIncludeKey: nil)

    public static func profile(for kind: InstanceKind) -> ServarrProfile? {
        switch kind {
        case .radarr: .radarr
        case .sonarr: .sonarr
        case .lidarr: .lidarr
        case .whisparr: .whisparr
        default: nil
        }
    }
}
