import Foundation
import MediaKit

/// The one mapping from an arr lookup (or library) record to a search row.
nonisolated extension SearchResult {
    init?(radarr r: ArrMovie, baseURL: String, sourceRank: Int = 0) {
        guard let tmdbId = r.tmdbId else { return nil }
        self.init(
            externalId: tmdbId, foreignId: String(tmdbId), title: r.title, subtitle: nil, year: r.year, rating: r.ratings?.tmdb?.value,
            votes: r.ratings?.tmdb?.votes ?? r.ratings?.imdb?.votes, imdb: r.ratings?.imdb?.value, rottenTomatoes: r.ratings?.rottenTomatoes?.value,
            metacritic: r.ratings?.metacritic?.value, overview: r.overview, runtime: r.runtime, genres: r.genres ?? [], network: r.studio,
            certification: r.certification, posterURL: (r.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: r.mediaServerKeys).0,
            source: .radarr, inLibraryArrId: (r.id ?? 0) != 0 ? r.id : nil, imdbId: r.imdbId, sourceRank: sourceRank)
        releaseStatus = r.status
    }

    init?(sonarr r: ArrSeries, baseURL: String, sourceRank: Int = 0) {
        guard let tvdbId = r.tvdbId else { return nil }
        self.init(
            externalId: tvdbId, foreignId: String(tvdbId), title: r.title,
            subtitle: r.statistics?.seasonCount.map { String(localized: "wait.frag.seasons \($0)", bundle: .module) },
            year: r.year, rating: r.ratings?.value, votes: r.ratings?.votes, imdb: nil, rottenTomatoes: nil, metacritic: nil,
            overview: r.overview, runtime: r.runtime, genres: r.genres ?? [], network: r.network, certification: nil,
            posterURL: (r.images ?? []).posterURL(baseURL: baseURL, mediaServerKeys: r.mediaServerKeys).0,
            source: .sonarr, inLibraryArrId: (r.id ?? 0) != 0 ? r.id : nil,
            imdbId: r.imdbId, sourceRank: sourceRank, tmdbTVId: (r.tmdbId ?? 0) != 0 ? r.tmdbId : nil)
        releaseStatus = r.status
    }

    init?(whisparr r: ArrMovie, baseURL: String, sourceRank: Int = 0) {
        let stableId: Int, foreign: String
        if let tmdb = r.tmdbId, tmdb != 0 { stableId = tmdb; foreign = String(tmdb) }
        else if let fid = r.foreignId, !fid.isEmpty { stableId = ArrLibraryMaps.foreignHashKey(fid); foreign = fid }
        else { return nil }
        self.init(
            externalId: stableId, foreignId: foreign, title: r.title, subtitle: nil, year: r.year, rating: r.ratings?.tmdb?.value,
            votes: r.ratings?.tmdb?.votes ?? r.ratings?.imdb?.votes, imdb: nil, rottenTomatoes: nil, metacritic: nil, overview: r.overview,
            runtime: r.runtime, genres: r.genres ?? [], network: r.studio, certification: nil,
            posterURL: (r.images ?? []).posterURL(baseURL: baseURL).0, source: .whisparr, sourceRank: sourceRank)
        releaseStatus = r.status
    }

    init?(album r: ArrAlbum, baseURL: String, sourceRank: Int = 0) {
        guard let foreign = r.foreignAlbumId, !foreign.isEmpty else { return nil }
        let year = r.releaseDate.flatMap { parseArrDate($0) }.map { Calendar.current.component(.year, from: $0) }
        let subtitle = [r.artist?.artistName, r.albumType].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        self.init(
            externalId: ArrLibraryMaps.foreignHashKey(foreign), foreignId: foreign, title: r.title, subtitle: subtitle.isEmpty ? r.disambiguation : subtitle,
            year: year, rating: r.ratings?.value, votes: r.ratings?.votes, imdb: nil, rottenTomatoes: nil, metacritic: nil, overview: r.overview,
            runtime: nil, genres: r.genres ?? [], network: nil, certification: nil, posterURL: r.coverURL(baseURL: baseURL).0,
            source: .lidarr, inLibraryArrId: (r.id ?? 0) != 0 ? r.id : nil, sourceRank: sourceRank, isLidarrAlbum: true)
    }

    init?(artist r: ArrArtist, baseURL: String, sourceRank: Int = 0) {
        guard let foreign = r.foreignArtistId, !foreign.isEmpty, let name = r.artistName, !name.isEmpty else { return nil }
        self.init(
            externalId: ArrLibraryMaps.foreignHashKey(foreign), foreignId: foreign, title: name, subtitle: r.disambiguation, year: nil,
            rating: r.ratings?.value, votes: r.ratings?.votes, imdb: nil, rottenTomatoes: nil, metacritic: nil, overview: r.overview, runtime: nil,
            genres: r.genres ?? [], network: nil, certification: nil,
            posterURL: (r.images ?? []).posterURL(baseURL: baseURL, coverTypes: ["poster", "cover"]).0,
            source: .lidarr, sourceRank: sourceRank)
    }
}
