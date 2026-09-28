import SwiftUI

extension DetailView {

    /// nil for a Sonarr series: its search lives per-season inside SeasonDetailView.
    var manualTarget: ManualSearchTarget? {
        guard let entityId = item.entityId else { return nil }
        switch item.source {
        case .radarr, .whisparr: return .movie(source: item.source, movieId: entityId, title: navTitleString)
        case .lidarr: return .album(albumId: entityId, title: navTitleString)
        case .sonarr: return nil
        }
    }

    /// The file a manual search would replace. Movies only: an album has no single file and a
    /// series doesn't open manual search from this level.
    var manualSearchContext: WaitCardContext {
        WaitCardContext(movie: radarrDetail, series: sonarrDetail, album: lidarrAlbum,
                        cast: cast, directors: directors, posterURL: item.posterURL,
                        posterApiKey: item.posterRequiresAuth ? arrAPIKey(for: item, in: configStore) : nil)
    }

    var manualSearchExistingFile: UpgradeDiffView.Side? {
        switch item.source {
        case .radarr, .whisparr:
            // Prefer the separately fetched file (it carries customFormats) over the stripped inline one.
            guard let file = radarrMovieFile ?? radarrDetail?.movieFile else { return nil }
            return UpgradeDiffView.side(file: file)
        case .sonarr, .lidarr:
            return nil
        }
    }

    /// A season pack has no single baseline, so each episode row diffs against its own file.
    func manualSearchEpisodeFiles(for target: ManualSearchTarget) -> [Int: UpgradeDiffView.Side] {
        guard item.source == .sonarr,
              let season = target.season
        else { return [:] }
        var out: [Int: UpgradeDiffView.Side] = [:]
        for episode in sonarrEpisodes where episode.seasonNumber == season {
            guard let number = episode.episodeNumber,
                  let file = episode.episodeFileId.flatMap({ sonarrEpisodeFiles[$0] }) else { continue }
            out[number] = UpgradeDiffView.side(file: file)
        }
        return out
    }

    /// Drives the CTA: spinner (in flight) → checkmark (queued) → spinner (sweep running).
    func startAutomaticSearch() {
        guard !searchRunning else { return }
        SearchFeedback.run($searchFeedback) {
            try await runAutomaticSearch()
            // Show it running now, or the CTA idles until the next poll and invites a second tap.
            searchRunning = true
            searchWatchToken += 1
        }
    }

    /// Bounded: each poll that sees a running search restarts the window, but a settled item
    /// stops polling instead of tapping the server forever.
    func watchSearchState() async {
        guard let entityId = item.entityId, item.source != .sonarr,
              let client = searchClient() else { return }
        var deadline = Date().addingTimeInterval(Self.searchWatchWindow)
        while !Task.isCancelled, Date() < deadline {
            let running = await client.isSearchRunning(entityId: entityId)
            if running != searchRunning {
                withAnimation(.easeInOut(duration: 0.2)) { searchRunning = running }
            }
            if running { deadline = Date().addingTimeInterval(Self.searchWatchWindow) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        if searchRunning {
            withAnimation(.easeInOut(duration: 0.2)) { searchRunning = false }
        }
    }

    /// Comfortably longer than a normal indexer sweep, and refreshed while one is live.
    private static let searchWatchWindow: TimeInterval = 180

    private func searchClient() -> (any ArrAPIClient)? {
        item.source == .sonarr ? nil : configStore.arrClient(for: item.source)
    }

    /// Movie / album only — series search is per-season in SeasonDetailView.
    private func runAutomaticSearch() async throws {
        guard let entityId = item.entityId else { return }
        switch item.source {
        case .radarr: try await configStore.radarrClient.searchMovie(movieId: entityId)
        case .whisparr: try await configStore.whisparrClient.searchMovie(movieId: entityId)
        case .lidarr: try await configStore.lidarrClient.searchAlbum(albumId: entityId)
        case .sonarr: break
        }
    }
}
