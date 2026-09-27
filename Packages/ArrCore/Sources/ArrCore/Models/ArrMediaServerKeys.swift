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

nonisolated public extension RadarrMovieDetail {
    var mediaServerKeys: [MediaServerExternalKey] {
        var keys: [MediaServerExternalKey] = []
        if let tmdbId { keys.append(.tmdbMovie(tmdbId)) }
        return keys
    }
}

nonisolated public extension SonarrSeriesDetail {
    var mediaServerKeys: [MediaServerExternalKey] {
        var keys: [MediaServerExternalKey] = []
        // TVDB first: Sonarr keys on it and every media server that scanned a
        // TV library will have stored it, whereas tmdbId is populated less
        // consistently across Sonarr versions.
        if let tvdbId { keys.append(.tvdb(tvdbId)) }
        if let tmdbId { keys.append(.tmdbSeries(tmdbId)) }
        return keys
    }
}

nonisolated public extension RadarrLibraryRecord {
    var mediaServerKeys: [MediaServerExternalKey] {
        tmdbId.map { [.tmdbMovie($0)] } ?? []
    }
}

nonisolated public extension SonarrLibraryRecord {
    var mediaServerKeys: [MediaServerExternalKey] {
        var keys: [MediaServerExternalKey] = []
        // TVDB first, tmdb as the second chance — same order and reasoning as
        // `SonarrSeriesDetail`, now that the library record decodes tmdbId too.
        if let tvdbId { keys.append(.tvdb(tvdbId)) }
        if let tmdbId, tmdbId > 0 { keys.append(.tmdbSeries(tmdbId)) }
        return keys
    }
}

nonisolated public extension UpcomingItem {
    /// Calendar entries carry the ids their arr embeds: TMDB for movies,
    /// TVDB for series. Music has neither.
    var mediaServerKeys: [MediaServerExternalKey] {
        var keys: [MediaServerExternalKey] = []
        if let tvdbId, tvdbId > 0 { keys.append(.tvdb(tvdbId)) }
        if let tmdbId, tmdbId > 0 { keys.append(source == .sonarr ? .tmdbSeries(tmdbId) : .tmdbMovie(tmdbId)) }
        return keys
    }
}

nonisolated public extension SearchResult {
    /// A lookup result's ids, in the form the media-server index is keyed by.
    /// Radarr results carry a TMDB id in `externalId`, Sonarr results a TVDB
    /// id — and TMDB-sourced series rows, which have no `externalId` yet, carry
    /// their TMDB series id in `tmdbTVId`. That last one is why these rows can
    /// be matched at all now: watched state used to be silently unavailable for
    /// every series that came from TMDB rather than from Sonarr's own lookup.
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



