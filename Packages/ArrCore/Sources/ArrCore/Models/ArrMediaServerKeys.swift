import Foundation
import MediaKit

/// Joined on provider ids, never titles (remakes, localisations, articles), most likely hit first.
/// No ids yields an empty array: no match, the arr's own artwork stands.

nonisolated public extension ArrMovie {
    var mediaServerKeys: [MediaServerExternalKey] {
        tmdbId.flatMap { $0 > 0 ? [.tmdbMovie($0)] : nil } ?? []
    }
}

nonisolated public extension ArrSeries {
    var mediaServerKeys: [MediaServerExternalKey] {
        var keys: [MediaServerExternalKey] = []
        // TVDB first: every server that scanned a TV library stored it; tmdbId is less consistent.
        if let tvdbId, tvdbId > 0 { keys.append(.tvdb(tvdbId)) }
        if let tmdbId, tmdbId > 0 { keys.append(.tmdbSeries(tmdbId)) }
        return keys
    }
}

nonisolated public extension UpcomingItem {
    /// TMDB for movies, TVDB for series. Music has neither.
    var mediaServerKeys: [MediaServerExternalKey] {
        var keys: [MediaServerExternalKey] = []
        if let tvdbId, tvdbId > 0 { keys.append(.tvdb(tvdbId)) }
        if let tmdbId, tmdbId > 0 { keys.append(source == .sonarr ? .tmdbSeries(tmdbId) : .tmdbMovie(tmdbId)) }
        return keys
    }
}

nonisolated public extension SearchResult {
    /// TMDB-sourced series rows have no `externalId` yet but carry their TMDB series id in `tmdbTVId`.
    var mediaServerKeys: [MediaServerExternalKey] {
        switch source {
        case .radarr, .whisparr:
            return externalId != 0 ? [.tmdbMovie(externalId)] : []
        case .sonarr:
            var keys: [MediaServerExternalKey] = []
            if externalId != 0 { keys.append(.tvdb(externalId)) }
            if let tmdbTVId, tmdbTVId > 0 { keys.append(.tmdbSeries(tmdbTVId)) }
            return keys
        case .lidarr:
            return []
        }
    }
}



