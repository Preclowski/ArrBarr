import Foundation

/// Handles on the facades. Views and view-models take them from the profile (`ConfigStore`) or, for a Settings
/// draft, from here; none of them builds a client.
public enum ServiceHandles {
    public static func arr(_ source: QueueItem.Source, config: ServiceConfig) -> any ArrAPIClient {
        switch source {
        case .radarr: RadarrClient(config: config)
        case .sonarr: SonarrClient(config: config)
        case .lidarr: LidarrClient(config: config)
        case .whisparr: WhisparrClient(config: config)
        }
    }

    public static func radarr(config: ServiceConfig) -> RadarrClient { RadarrClient(config: config) }

    public static func search(_ source: QueueItem.Source, config: ServiceConfig) -> SearchClient {
        SearchClient(config: config, source: source)
    }

    public static func tmdb(apiKey: String) -> TMDBClient { TMDBClient(apiKey: apiKey) }

    public static func mediaServer(config: MediaServerConfig) -> MediaServerClient? { MediaServerClientFactory.make(config: config) }

    /// One round trip proving a draft works: the arr's version, or the download client's greeting.
    public static func testConnection(_ kind: ServiceKind, config: ServiceConfig) async throws -> String {
        switch kind {
        case .radarr: try await RadarrClient(config: config).testConnection()
        case .sonarr: try await SonarrClient(config: config).testConnection()
        case .lidarr: try await LidarrClient(config: config).testConnection()
        case .whisparr: try await WhisparrClient(config: config).testConnection()
        case .sabnzbd: try await SabnzbdClient(config: config).testConnection()
        case .nzbget: try await NzbgetClient(config: config).testConnection()
        case .qbittorrent: try await QbittorrentClient(config: config).testConnection()
        case .transmission: try await TransmissionClient(config: config).testConnection()
        case .rtorrent: try await RtorrentClient(config: config).testConnection()
        case .deluge: try await DelugeClient(config: config).testConnection()
        }
    }
}

public extension ConfigStore {
    var radarrClient: RadarrClient { RadarrClient(config: radarr) }
    var sonarrClient: SonarrClient { SonarrClient(config: sonarr) }
    var lidarrClient: LidarrClient { LidarrClient(config: lidarr) }
    var whisparrClient: WhisparrClient { WhisparrClient(config: whisparr) }
    var tmdbClient: TMDBClient { TMDBClient(apiKey: tmdbApiKey) }
    func arrClient(for source: QueueItem.Source) -> any ArrAPIClient { ServiceHandles.arr(source, config: serviceConfig(for: source)) }
    func searchClient(for source: QueueItem.Source) -> SearchClient { SearchClient(config: serviceConfig(for: source), source: source) }
    var mediaServerClient: MediaServerClient? { MediaServerClientFactory.make(config: mediaServer) }
}
