import Foundation

/// Narrow scopes gate which clients fire at all, so scoping also saves requests.
nonisolated public enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all, movie, series, album, people, whisparr

    public var id: String { rawValue }

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

    /// Shared so every search surface offers the same set.
    @MainActor
    public static func available(for store: ConfigStore) -> [SearchScope] {
        var out: [SearchScope] = [.all]
        if store.radarr.isVisible { out.append(.movie) }
        if store.sonarr.isVisible { out.append(.series) }
        if store.lidarr.isVisible { out.append(.album) }
        if !store.tmdbApiKey.isEmpty { out.append(.people) }
        if store.whisparr.isVisible { out.append(.whisparr) }
        return out
    }

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

    public var searchesPeople: Bool { self == .all || self == .people }
}
