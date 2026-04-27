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
    private var cachedTransmissionClient: TransmissionClient?
    private var cachedTransmissionConfig: ServiceConfig?
    private var cachedDelugeClient: DelugeClient?
    private var cachedDelugeConfig: ServiceConfig?

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
            try await performUsenet(action, downloadId: downloadId)
        case .torrent:
            try await performTorrent(action, downloadId: downloadId)
        case .unknown:
            throw AggregateError.downloadProtocolUnknown
        }
    }

    private func performUsenet(_ action: Action, downloadId: String) async throws {
        let sabCfg = configStore.sabnzbd
        if sabCfg.isConfigured, !sabCfg.apiKey.isEmpty {
            let sab = SabnzbdClient(config: sabCfg)
            try await sab.perform(sabAction(action), nzoId: downloadId)
            return
        }

        let nzbgetCfg = configStore.nzbget
        if nzbgetCfg.isConfigured {
            let nzbget = NzbgetClient(config: nzbgetCfg)
            try await nzbget.perform(nzbgetAction(action), nzbId: downloadId)
            return
        }

        throw AggregateError.downloadClientNotConfigured(.usenet)
    }

    private func performTorrent(_ action: Action, downloadId: String) async throws {
        let qbitCfg = configStore.qbittorrent
        if qbitCfg.isConfigured {
            let qbit = qbitClient(for: qbitCfg)
            try await qbit.perform(qbitAction(action), hash: downloadId)
            return
        }

        let transCfg = configStore.transmission
        if transCfg.isConfigured {
            let client = transmissionClient(for: transCfg)
            try await client.perform(transmissionAction(action), hash: downloadId)
            return
        }

        let rtCfg = configStore.rtorrent
        if rtCfg.isConfigured {
            let client = RtorrentClient(config: rtCfg)
            try await client.perform(rtorrentAction(action), hash: downloadId)
            return
        }

        let delugeCfg = configStore.deluge
        if delugeCfg.isConfigured {
            let client = delugeClient(for: delugeCfg)
            try await client.perform(delugeAction(action), hash: downloadId)
            return
        }

        throw AggregateError.downloadClientNotConfigured(.torrent)
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

    private func transmissionClient(for cfg: ServiceConfig) -> TransmissionClient {
        if let cached = cachedTransmissionClient, cachedTransmissionConfig == cfg {
            return cached
        }
        let client = TransmissionClient(config: cfg)
        cachedTransmissionClient = client
        cachedTransmissionConfig = cfg
        return client
    }

    private func delugeClient(for cfg: ServiceConfig) -> DelugeClient {
        if let cached = cachedDelugeClient, cachedDelugeConfig == cfg {
            return cached
        }
        let client = DelugeClient(config: cfg)
        cachedDelugeClient = client
        cachedDelugeConfig = cfg
        return client
    }

    private func sabAction(_ a: Action) -> SabnzbdClient.Action {
        switch a { case .pause: .pause; case .resume: .resume; case .delete: .delete }
    }

    private func qbitAction(_ a: Action) -> QbittorrentClient.Action {
        switch a { case .pause: .pause; case .resume: .resume; case .delete: .delete }
    }

    private func nzbgetAction(_ a: Action) -> NzbgetClient.Action {
        switch a { case .pause: .pause; case .resume: .resume; case .delete: .delete }
    }

    private func transmissionAction(_ a: Action) -> TransmissionClient.Action {
        switch a { case .pause: .pause; case .resume: .resume; case .delete: .delete }
    }

    private func rtorrentAction(_ a: Action) -> RtorrentClient.Action {
        switch a { case .pause: .pause; case .resume: .resume; case .delete: .delete }
    }

    private func delugeAction(_ a: Action) -> DelugeClient.Action {
        switch a { case .pause: .pause; case .resume: .resume; case .delete: .delete }
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
