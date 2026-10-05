import SwiftUI
import os

extension DetailView {
    // MARK: - Loading

    /// nil on any failure — the chip simply doesn't render.
    private static func profileName(id: Int?, config: ServiceConfig, source: QueueItem.Source) async -> String? {
        guard let id else { return nil }
        return await SearchClient.profileNameMap(config: config, source: source)[id]
    }

    /// Two batches (the arr's record, then TMDB's credits and countries), each landing in one animated
    /// change: assigned field by field, every await reflowed the page and the overview jumped.
    static let landing: Animation = .smooth(duration: 0.28)

    func load(showSpinner: Bool = true) async {
        if showSpinner { loading = true }
        defer { if showSpinner { withAnimation(Self.landing) { loading = false } } }
        guard let entityId = item.entityId else { return }
        do {
            switch item.source {
            case .radarr:
                let client = configStore.radarrClient
                async let detail = client.fetchMovieDetails(id: entityId)
                // `/movie/{id}` omits customFormats on the inline movieFile; on failure (older Radarr)
                // the inline one still backs the banner.
                async let file = (try? client.fetchMovieFile(movieId: entityId)) ?? nil
                async let profiles = SearchClient.profileNameMap(config: configStore.radarr, source: .radarr)
                let movie = try await detail
                let movieFile = await file
                let profileNames = await profiles
                withAnimation(Self.landing) {
                    radarrDetail = movie
                    radarrMovieFile = movieFile
                    qualityProfileName = movie.qualityProfileId.flatMap { profileNames[$0] }
                }
                async let movieCountries = CountryProvider.movieCountries(tmdbId: movie.tmdbId, configStore: configStore)
                let movieCredits = await CastProvider.movieCredits(
                    radarrMovieId: entityId, tmdbId: movie.tmdbId, configStore: configStore)
                let names = await movieCountries
                withAnimation(Self.landing) {
                    cast = movieCredits.cast
                    directors = movieCredits.directors
                    countries = names
                }
            case .sonarr:
                let client = configStore.sonarrClient
                async let d = client.fetchSeriesDetails(id: entityId)
                async let eps = client.fetchEpisodes(seriesId: entityId)
                async let files = (try? client.fetchEpisodeFileMap(seriesId: entityId)) ?? [:]
                async let profiles = SearchClient.profileNameMap(config: configStore.sonarr, source: .sonarr)
                let series = try await d
                let episodes = try await eps
                let fileMap = await files
                let profileNames = await profiles
                withAnimation(Self.landing) {
                    sonarrDetail = series
                    sonarrEpisodes = episodes
                    episodeIdBySlot = Dictionary(
                        episodes.compactMap { ep in
                            guard let sn = ep.seasonNumber, let en = ep.episodeNumber else { return nil }
                            return (EpisodeSlot(season: sn, episode: en), ep.id)
                        },
                        // A duplicated slot keeps the first record — the one the episode list renders.
                        uniquingKeysWith: { first, _ in first }
                    )
                    sonarrEpisodeFiles = fileMap
                    qualityProfileName = series.qualityProfileId.flatMap { profileNames[$0] }
                }
                async let seriesCountries = CountryProvider.seriesCountries(
                    tmdbId: series.tmdbId, tvdbId: series.tvdbId, configStore: configStore)
                let seriesCredits = await CastProvider.seriesCredits(
                    tmdbId: series.tmdbId, tvdbId: series.tvdbId, configStore: configStore)
                let names = await seriesCountries
                withAnimation(Self.landing) {
                    cast = seriesCredits.cast
                    directors = seriesCredits.directors
                    countries = names
                }
            case .lidarr:
                let client = configStore.lidarrClient
                async let a = client.fetchAlbumDetails(id: entityId)
                async let ts = client.fetchTracks(albumId: entityId)
                async let fs = client.fetchTrackFiles(albumId: entityId)
                lidarrAlbum = try await a
                lidarrTracks = try await ts
                do { lidarrTrackFiles = try await fs } catch {
                    Logger.extras.debug("lidarr track files failed: \(error.logKind, privacy: .public): \(error.localizedDescription, privacy: .private)")
                    lidarrTrackFiles = []
                }
            case .whisparr:
                let client = configStore.whisparrClient
                radarrDetail = try await client.fetchMovieDetails(id: entityId)
                qualityProfileName = await Self.profileName(
                    id: radarrDetail?.qualityProfileId, config: configStore.whisparr, source: .whisparr)            }
        } catch {
            viewModel.reportFailure("toast.loadFailed.title", error, source: item.source) { Task { await load() } }
        }
    }
}
