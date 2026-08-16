import Foundation

/// Mutable layer over the static detail fixtures — the demo's stand-in for
/// the arrs' monitored flags. Same philosophy as `DemoQueueState`: fixtures
/// are rebuilt on every (mock) fetch, so an optimistic bookmark flip was
/// snapped back by the silent refetch that follows it — the toggle looked
/// broken in the one build meant to show it off. Flips land here and every
/// demo detail fetch reads the fixtures back through `apply`.
///
/// In-memory on purpose — a fresh demo visit gets the curated flags.
@MainActor
enum DemoMonitorState {
    private static var movies: [Int: Bool] = [:]
    private static var series: [Int: Bool] = [:]
    private static var seasons: [String: Bool] = [:]   // "seriesId-seasonNumber"
    private static var episodes: [Int: Bool] = [:]
    private static var albums: [Int: Bool] = [:]
    private static var artists: [Int: Bool] = [:]

    // MARK: - Writes (the clients' demo branches)

    static func setMovie(_ id: Int, monitored: Bool) { movies[id] = monitored }
    static func setSeries(_ id: Int, monitored: Bool) { series[id] = monitored }
    static func setAlbum(_ id: Int, monitored: Bool) { albums[id] = monitored }
    static func setArtist(_ id: Int, monitored: Bool) { artists[id] = monitored }
    static func setEpisodes(_ ids: [Int], monitored: Bool) {
        for id in ids { episodes[id] = monitored }
    }

    /// Mirrors Sonarr's server-side behaviour: flipping a season cascades to
    /// every episode in it.
    static func setSeason(seriesId: Int, seasonNumber: Int, monitored: Bool) {
        seasons["\(seriesId)-\(seasonNumber)"] = monitored
        for ep in DemoMocks.sonarrEpisodes(seriesId: seriesId) where ep.seasonNumber == seasonNumber {
            episodes[ep.id] = monitored
        }
    }

    // MARK: - Reads (fixture post-processing)

    static func apply(movie detail: RadarrMovieDetail?) -> RadarrMovieDetail? {
        guard var copy = detail, let m = movies[copy.id] else { return detail }
        copy.monitored = m
        return copy
    }

    static func apply(series detail: SonarrSeriesDetail?) -> SonarrSeriesDetail? {
        guard var copy = detail else { return detail }
        if let m = series[copy.id] { copy.monitored = m }
        if var s = copy.seasons {
            for i in s.indices {
                if let m = seasons["\(copy.id)-\(s[i].seasonNumber)"] { s[i].monitored = m }
            }
            copy.seasons = s
        }
        return copy
    }

    static func apply(episodes eps: [SonarrEpisodeDetail]) -> [SonarrEpisodeDetail] {
        eps.map { ep in
            guard let m = episodes[ep.id] else { return ep }
            var copy = ep
            copy.monitored = m
            return copy
        }
    }

    static func apply(album detail: LidarrAlbumDetail?) -> LidarrAlbumDetail? {
        guard var copy = detail, let m = albums[copy.id] else { return detail }
        copy.monitored = m
        return copy
    }

    static func apply(artist detail: LidarrArtistDetail?) -> LidarrArtistDetail? {
        guard var copy = detail, let m = artists[copy.id] else { return detail }
        copy.monitored = m
        return copy
    }

    /// See `DemoQueueState.reset` — leaving demo wipes the demo profile, and
    /// these flips have to go with it.
    static func reset() {
        movies.removeAll()
        series.removeAll()
        seasons.removeAll()
        episodes.removeAll()
        albums.removeAll()
        artists.removeAll()
    }
}
