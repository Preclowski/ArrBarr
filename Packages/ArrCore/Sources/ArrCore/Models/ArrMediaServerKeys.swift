import Foundation

/// How each arr record identifies itself to the media server.
///
/// The join between "what Radarr has" and "what Plex has" is provider ids on
/// both sides — never titles, which disagree across remakes, localisations and
/// leading articles. Each record type exposes the ids it happens to carry, in
/// the order most likely to hit: Radarr keys on TMDB, Sonarr on TVDB, and both
/// servers store whichever ones their scanner found.
///
/// Records with no ids yield an empty array, which the index treats as "no
/// match" — the arr's own artwork stands.

public extension RadarrMovieDetail {
    var mediaServerKeys: [MediaServerExternalKey] {
        var keys: [MediaServerExternalKey] = []
        if let tmdbId { keys.append(.tmdb(tmdbId)) }
        return keys
    }
}

public extension SonarrSeriesDetail {
    var mediaServerKeys: [MediaServerExternalKey] {
        var keys: [MediaServerExternalKey] = []
        // TVDB first: Sonarr keys on it and every media server that scanned a
        // TV library will have stored it, whereas tmdbId is populated less
        // consistently across Sonarr versions.
        if let tvdbId { keys.append(.tvdb(tvdbId)) }
        if let tmdbId { keys.append(.tmdb(tmdbId)) }
        return keys
    }
}

public extension RadarrLibraryRecord {
    var mediaServerKeys: [MediaServerExternalKey] {
        tmdbId.map { [.tmdb($0)] } ?? []
    }
}

public extension SonarrLibraryRecord {
    var mediaServerKeys: [MediaServerExternalKey] {
        tvdbId.map { [.tvdb($0)] } ?? []
    }
}

public extension SearchResult {
    /// A lookup result's ids, in the form the media-server index is keyed by.
    /// Radarr results carry a TMDB id in `.id`, Sonarr results a TVDB id —
    /// except TMDB-sourced series rows, which carry `0` (see
    /// `TMDBSearchMapping.series`) and therefore can't be matched at all.
    var mediaServerKeys: [MediaServerExternalKey] {
        guard id != 0 else { return [] }
        switch source {
        case .radarr, .whisparr: return [.tmdb(id)]
        case .sonarr:            return [.tvdb(id)]
        case .lidarr:            return []
        }
    }
}

public extension RadarrCalendarRecord {
    var mediaServerKeys: [MediaServerExternalKey] {
        tmdbId.map { [.tmdb($0)] } ?? []
    }
}

public extension SonarrSeries {
    var mediaServerKeys: [MediaServerExternalKey] {
        tvdbId.map { [.tvdb($0)] } ?? []
    }
}

public extension RadarrMovie {
    var mediaServerKeys: [MediaServerExternalKey] {
        tmdbId.map { [.tmdb($0)] } ?? []
    }
}
