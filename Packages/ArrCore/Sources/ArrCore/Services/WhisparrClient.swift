import Foundation
import MediaKit

/// Whisparr v3 is Radarr's vocabulary; the capability probe marks a v2 instance, whose movie resources are unsupported.
nonisolated public struct WhisparrClient: ArrAPIClient {
    public let config: ServiceConfig
    public let source: QueueItem.Source = .whisparr
    public let serviceName = "Whisparr"

    init(config: ServiceConfig) { self.config = config }

    func fetchQueue() async throws -> [QueueItem] {
        let c = try await context()
        return try await ArrQueueLoader.items(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL)
    }
    func fetchCalendar() async throws -> [UpcomingItem] {
        let c = try await context()
        return try await ArrQueueLoader.upcoming(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL)
    }
    func fetchHistory(page: Int, pageSize: Int, entityId: Int? = nil) async throws -> HistoryPage {
        let c = try await context()
        return try await ArrQueueLoader.history(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL, page: page, pageSize: pageSize, entityId: entityId)
    }

    func fetchMovieFile(movieId: Int) async throws -> ArrCore.ArrFile? { try await read([ArrCore.ArrFile].self) { $0.movieFiles([movieId]) }.first }
    func fetchAllMovies() async throws -> [WhisparrLibraryRecord] { try await read([WhisparrLibraryRecord].self, policy: .mustRevalidate) { $0.movies() } }
    func fetchMovieDetails(id: Int) async throws -> RadarrMovieDetail { try await read(RadarrMovieDetail.self) { $0.movie(id: id) } }
}
