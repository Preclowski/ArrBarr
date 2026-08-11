import Foundation

/// Which backends a universal search hits. Chosen from the scope chip on the
/// search field; `all` is the default and fires every configured arr plus the
/// TMDB people lookup. The narrow scopes gate which clients fire at all — an
/// album search never pings Radarr, a people search only hits TMDB — so scoping
/// is both a relevance filter and a request saver.
public enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all, movie, series, album, people, whisparr

    public var id: String { rawValue }

    /// SF Symbol for the chip.
    public var symbol: String {
        switch self {
        case .all:      return "square.stack.3d.up"
        case .movie:    return "film"
        case .series:   return "tv"
        case .album:    return "music.note"
        case .people:   return "person"
        case .whisparr: return "flame"
        }
    }

    /// Localization key for the chip / menu label.
    public var labelKey: String {
        switch self {
        case .all:      return "search.scope.all"
        case .movie:    return "search.scope.movies"
        case .series:   return "search.scope.series"
        case .album:    return "search.scope.albums"
        case .people:   return "search.scope.people"
        case .whisparr: return "search.scope.whisparr"
        }
    }

    /// Whether this scope lets a given arr source fire. `people` allows none —
    /// it's TMDB-only.
    public func allows(_ source: QueueItem.Source) -> Bool {
        switch self {
        case .all:      return true
        case .movie:    return source == .radarr
        case .series:   return source == .sonarr
        case .album:    return source == .lidarr
        case .whisparr: return source == .whisparr
        case .people:   return false
        }
    }

    /// Whether this scope runs the TMDB people lookup.
    public var searchesPeople: Bool { self == .all || self == .people }
}
