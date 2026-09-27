import Foundation
import MediaKit

nonisolated public struct LidarrClient: ArrAPIClient {
    public let config: ServiceConfig
    public let source: QueueItem.Source = .lidarr
    public let serviceName = "Lidarr"

    init(config: ServiceConfig) { self.config = config }

    func fetchQueue() async throws -> [QueueItem] {
        let c = try await context()
        return try await ArrQueueLoader.items(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL)
    }
    func fetchCalendar() async throws -> [UpcomingItem] {
        let c = try await context()
        return try await ArrQueueLoader.upcoming(source: source, gateway: c.gateway, service: c.service, baseURL: config.baseURL)
    }

    func fetchTrackFiles(albumId: Int) async throws -> [ArrFile] { try await read { $0.filesOf(parent: albumId) } }
    func fetchAlbumDetails(id: Int) async throws -> LidarrAlbumDetail { try await read(LidarrAlbumDetail.self) { $0.album(id: id) } }
    func fetchTracks(albumId: Int) async throws -> [LidarrTrackDetail] { try await read([LidarrTrackDetail].self) { $0.tracks(albumID: albumId) } }
    func fetchArtistDetails(id: Int) async throws -> LidarrArtistDetail { try await read(LidarrArtistDetail.self) { $0.artist(id: id) } }
    /// See `RadarrClient.fetchAllMovies(revalidate:)`.
    func fetchAllArtists(revalidate: Bool = true) async throws -> [LidarrLibraryRecord] {
        (try? await fetchAllArtistsFetched(revalidate: revalidate).value) ?? []
    }

    func fetchAllArtistsFetched(revalidate: Bool = true) async throws -> Fetched<[LidarrLibraryRecord]> {
        try await readCacheFirst([LidarrLibraryRecord].self, revalidate: revalidate) { $0.artists() }
    }
    func fetchArtistAlbums(artistId: Int) async throws -> [LidarrAlbumListRecord] { try await read([LidarrAlbumListRecord].self) { $0.albums(artistID: artistId) } }
    func setAlbumMonitored(albumId: Int, monitored: Bool) async throws { try await run { $0.setAlbumMonitored(albumID: albumId, monitored) } }
    func setArtistMonitored(artistId: Int, monitored: Bool) async throws { try await run { $0.setMonitored(entityID: artistId, monitored) } }
    func searchAlbum(albumId: Int) async throws { try await run { $0.search(.albums([albumId])) } }
}
