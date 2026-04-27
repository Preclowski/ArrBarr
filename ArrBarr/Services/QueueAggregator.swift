import Foundation

@MainActor
final class QueueAggregator {
    enum AggregateError: LocalizedError {
        case noDownloadId
        case downloadProtocolUnknown
        case downloadClientNotConfigured(QueueItem.DownloadProtocol)

        var errorDescription: String? {
            switch self {
            case .noDownloadId: return "No download ID — item hasn't reached the client yet"
            case .downloadProtocolUnknown: return "Unknown download protocol"
            case .downloadClientNotConfigured(let p):
                return "Client (\(p.rawValue)) is not configured"
            }
        }
    }

    enum Action { case pause, resume, delete }

    private let configStore: ConfigStore
    private var cachedQbitClient: QbittorrentClient?
    private var cachedQbitConfig: ServiceConfig?

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    func fetch() async -> AggregateResult {
        let radarrCfg = configStore.radarr
        let sonarrCfg = configStore.sonarr

        async let radarr = Self.safeFetch { try await RadarrClient(config: radarrCfg).fetchQueue() }
        async let sonarr = Self.safeFetch { try await SonarrClient(config: sonarrCfg).fetchQueue() }
        let (r, s) = await (radarr, sonarr)
        return AggregateResult(
            radarr: r.items, sonarr: s.items,
            radarrError: r.error, sonarrError: s.error
        )
    }

    func fetchUpcoming() async -> [UpcomingItem] {
        let radarrCfg = configStore.radarr
        let sonarrCfg = configStore.sonarr

        async let radarr = Self.safeFetchUpcoming { try await RadarrClient(config: radarrCfg).fetchCalendar() }
        async let sonarr = Self.safeFetchUpcoming { try await SonarrClient(config: sonarrCfg).fetchCalendar() }
        let (r, s) = await (radarr, sonarr)
        return (r + s).sorted { $0.airDate < $1.airDate }
    }

    private static func safeFetch(_ block: () async throws -> [QueueItem]) async -> (items: [QueueItem], error: String?) {
        do {
            return (try await block(), nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ([], message)
        }
    }

    private static func safeFetchUpcoming(_ block: () async throws -> [UpcomingItem]) async -> [UpcomingItem] {
        do { return try await block() } catch { return [] }
    }

    func perform(_ action: Action, on item: QueueItem) async throws {
        guard let downloadId = item.downloadId, !downloadId.isEmpty else {
            throw AggregateError.noDownloadId
        }

        switch item.downloadProtocol {
        case .usenet:
            let cfg = configStore.sabnzbd
            guard cfg.isConfigured, !cfg.apiKey.isEmpty else {
                throw AggregateError.downloadClientNotConfigured(.usenet)
            }
            let sab = SabnzbdClient(config: cfg)
            try await sab.perform(sabAction(action), nzoId: downloadId)

        case .torrent:
            let cfg = configStore.qbittorrent
            guard cfg.isConfigured else {
                throw AggregateError.downloadClientNotConfigured(.torrent)
            }
            let qbit = qbitClient(for: cfg)
            try await qbit.perform(qbitAction(action), hash: downloadId)

        case .unknown:
            throw AggregateError.downloadProtocolUnknown
        }
    }

    // Reuse qBittorrent client to avoid re-login on every action.
    private func qbitClient(for cfg: ServiceConfig) -> QbittorrentClient {
        if let cached = cachedQbitClient, cachedQbitConfig == cfg {
            return cached
        }
        let client = QbittorrentClient(config: cfg)
        cachedQbitClient = client
        cachedQbitConfig = cfg
        return client
    }

    private func sabAction(_ a: Action) -> SabnzbdClient.Action {
        switch a {
        case .pause: return .pause
        case .resume: return .resume
        case .delete: return .delete
        }
    }

    private func qbitAction(_ a: Action) -> QbittorrentClient.Action {
        switch a {
        case .pause: return .pause
        case .resume: return .resume
        case .delete: return .delete
        }
    }
}

struct AggregateResult: Equatable {
    let radarr: [QueueItem]
    let sonarr: [QueueItem]
    var radarrError: String?
    var sonarrError: String?

    var totalCount: Int { radarr.count + sonarr.count }
    var activeCount: Int {
        (radarr + sonarr).filter { $0.status != .completed }.count
    }
}
