import Foundation
import MediaKit

nonisolated public struct SonarrClient: ArrAPIClient {
    public let config: ServiceConfig
    public let source: QueueItem.Source = .sonarr
    public let serviceName = "Sonarr"

    init(config: ServiceConfig) { self.config = config }

    func fetchQueue() async throws -> [QueueItem] {
        let c = try await context()
        return try await ArrQueueLoader.items(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL)
    }
    func fetchCalendar() async throws -> [UpcomingItem] {
        let c = try await context()
        return try await ArrQueueLoader.upcoming(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL)
    }

    func fetchEpisodeFileMap(seriesId: Int) async throws -> [Int: ArrFile] {
        let files = try await read { $0.filesOf(parent: seriesId) }
        return Dictionary(files.compactMap { file in file.id.map { ($0, file) } }, uniquingKeysWith: { first, _ in first })
    }

    func fetchSeriesDetails(id: Int) async throws -> ArrSeries { try await read { $0.seriesDetails(id: id) } }
    func fetchEpisodes(seriesId: Int) async throws -> [ArrEpisode] { try await read { $0.episodes(seriesID: seriesId) } }
    func searchEpisodes(episodeIds: [Int]) async throws { try await run { $0.search(.episodes(episodeIds)) } }
    func searchSeason(seriesId: Int, seasonNumber: Int) async throws { try await run { $0.search(.season(seriesID: seriesId, season: seasonNumber)) } }
    func setSeriesMonitored(seriesId: Int, monitored: Bool) async throws { try await run { $0.setMonitored(entityID: seriesId, monitored) } }
    func setEpisodesMonitored(episodeIds: [Int], monitored: Bool) async throws { try await run { $0.setEpisodesMonitored(ids: episodeIds, monitored) } }
    func setSeasonMonitored(seriesId: Int, seasonNumber: Int, monitored: Bool) async throws {
        try await run { $0.setSeasonMonitored(seriesID: seriesId, season: seasonNumber, monitored) }
    }
    func lookupSeries(term: String) async throws -> [ArrSeries] { try await read { $0.lookupSeries(term: term) } }
    /// `revalidate: false` serves whatever the on-disk store holds and says so
    /// in `isStale`, refreshing behind the caller — what the Library's first
    /// paint of a session wants.
    func fetchAllSeries(revalidate: Bool = true) async throws -> [ArrSeries] {
        try await fetchAllSeriesFetched(revalidate: revalidate).value
    }

    func fetchAllSeriesFetched(revalidate: Bool = true) async throws -> Fetched<[ArrSeries]> {
        try await readCacheFirst(revalidate: revalidate) { $0.series() }
    }
}
