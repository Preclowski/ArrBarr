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

    func fetchMovieFile(movieId: Int) async throws -> ArrFile? { try await read([ArrFile].self) { $0.movieFiles([movieId]) }.first }
    /// `revalidate: false` serves whatever the on-disk store holds and says so
    /// in `isStale`, refreshing behind the caller — what the Library's first
    /// paint of a session wants.
    func fetchAllMovies(revalidate: Bool = true) async throws -> [WhisparrLibraryRecord] {
        try await fetchAllMoviesFetched(revalidate: revalidate).value
    }

    func fetchAllMoviesFetched(revalidate: Bool = true) async throws -> Fetched<[WhisparrLibraryRecord]> {
        try await readCacheFirst([WhisparrLibraryRecord].self, revalidate: revalidate) { $0.movies() }
    }
    func fetchMovieDetails(id: Int) async throws -> RadarrMovieDetail { try await read(RadarrMovieDetail.self) { $0.movie(id: id) } }
}
