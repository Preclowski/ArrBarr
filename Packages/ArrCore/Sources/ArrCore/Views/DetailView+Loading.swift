import SwiftUI
import os

extension DetailView {
    // MARK: - Loading

    /// nil on any failure — the chip simply doesn't render.
    private static func profileName(id: Int?, config: ServiceConfig, source: QueueItem.Source) async -> String? {
        guard let id else { return nil }
        return await SearchClient.profileNameMap(config: config, source: source)[id]
    }

    func load(showSpinner: Bool = true) async {
        if showSpinner { loading = true }
        loadError = nil
        defer { if showSpinner { loading = false } }
        guard let entityId = item.entityId else {
            loadError = "No entity id"
            return
        }
        do {
            switch item.source {
            case .radarr:
                let client = configStore.radarrClient
                async let detail = client.fetchMovieDetails(id: entityId)
                // `/movie/{id}` omits customFormats on the inline movieFile; on failure (older Radarr)
                // the inline one still backs the banner.
                async let file = (try? client.fetchMovieFile(movieId: entityId)) ?? nil
                radarrDetail = try await detail
                radarrMovieFile = await file
                qualityProfileName = await Self.profileName(
                    id: radarrDetail?.qualityProfileId, config: configStore.radarr, source: .radarr)
                async let movieCountries = CountryProvider.movieCountries(
                    tmdbId: radarrDetail?.tmdbId, configStore: configStore)
                let movieCredits = await CastProvider.movieCredits(
                    radarrMovieId: entityId, tmdbId: radarrDetail?.tmdbId, configStore: configStore)
                cast = movieCredits.cast
                directors = movieCredits.directors
                countries = await movieCountries
            case .sonarr:
                let client = configStore.sonarrClient
                async let d = client.fetchSeriesDetails(id: entityId)
                async let eps = client.fetchEpisodes(seriesId: entityId)
                async let files = (try? client.fetchEpisodeFileMap(seriesId: entityId)) ?? [:]
                sonarrDetail = try await d
                sonarrEpisodes = try await eps
                episodeIdBySlot = Dictionary(
                    sonarrEpisodes.compactMap { ep in
                        guard let sn = ep.seasonNumber, let en = ep.episodeNumber else { return nil }
                        return (EpisodeSlot(season: sn, episode: en), ep.id)
                    },
                    // A duplicated slot keeps the first record — the one the episode list renders.
                    uniquingKeysWith: { first, _ in first }
                )
                sonarrEpisodeFiles = await files
                qualityProfileName = await Self.profileName(
                    id: sonarrDetail?.qualityProfileId, config: configStore.sonarr, source: .sonarr)
                async let seriesCountries = CountryProvider.seriesCountries(
                    tmdbId: sonarrDetail?.tmdbId, tvdbId: sonarrDetail?.tvdbId, configStore: configStore)
                let seriesCredits = await CastProvider.seriesCredits(
                    tmdbId: sonarrDetail?.tmdbId, tvdbId: sonarrDetail?.tvdbId, configStore: configStore)
                cast = seriesCredits.cast
                directors = seriesCredits.directors
                countries = await seriesCountries
            case .lidarr:
                let client = configStore.lidarrClient
                async let a = client.fetchAlbumDetails(id: entityId)
                async let ts = client.fetchTracks(albumId: entityId)
                async let fs = client.fetchTrackFiles(albumId: entityId)
                lidarrAlbum = try await a
                lidarrTracks = try await ts
                do { lidarrTrackFiles = try await fs } catch {
                    Logger.extras.debug("lidarr track files failed: \(error.localizedDescription, privacy: .public)")
                    lidarrTrackFiles = []
                }
            case .whisparr:
                let client = configStore.whisparrClient
                radarrDetail = try await client.fetchMovieDetails(id: entityId)
                qualityProfileName = await Self.profileName(
                    id: radarrDetail?.qualityProfileId, config: configStore.whisparr, source: .whisparr)            }
        } catch {
            loadError = "Couldn't load details: \(error.localizedDescription)"
        }
    }
}
