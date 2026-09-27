import Foundation
import MediaKit

nonisolated public struct LidarrClient: ArrAPIClient {
    public let config: ServiceConfig
    public let source: QueueItem.Source = .lidarr

    init(config: ServiceConfig) { self.config = config }

    func fetchTrackFiles(albumId: Int) async throws -> [ArrFile] { try await read { $0.filesOf(parent: albumId) } }
    func fetchAlbumDetails(id: Int) async throws -> ArrAlbum { try await read { $0.album(id: id) } }
    func fetchTracks(albumId: Int) async throws -> [ArrTrack] { try await read { $0.tracks(albumID: albumId) } }
    func fetchArtistDetails(id: Int) async throws -> ArrArtist { try await read { $0.artist(id: id) } }
    /// See `RadarrClient.fetchAllMovies(revalidate:)`.
    func fetchAllArtists(revalidate: Bool = true) async throws -> [ArrArtist] {
        try await fetchAllArtistsFetched(revalidate: revalidate).value
    }

    func fetchAllArtistsFetched(revalidate: Bool = true) async throws -> Fetched<[ArrArtist]> {
        try await readCacheFirst(revalidate: revalidate) { $0.artists() }
    }
    func fetchArtistAlbums(artistId: Int) async throws -> [ArrAlbum] { try await read { $0.albums(artistID: artistId) } }
    func setAlbumMonitored(albumId: Int, monitored: Bool) async throws { try await run { $0.setAlbumMonitored(albumID: albumId, monitored) } }
    func setArtistMonitored(artistId: Int, monitored: Bool) async throws { try await run { $0.setMonitored(entityID: artistId, monitored) } }
    func searchAlbum(albumId: Int) async throws { try await run { $0.search(.albums([albumId])) } }
}
