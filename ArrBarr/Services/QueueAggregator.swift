import Foundation

@MainActor
final class QueueAggregator {
    enum AggregateError: LocalizedError {
        case noDownloadId
        case downloadProtocolUnknown
        case downloadClientNotConfigured(QueueItem.DownloadProtocol)

        var errorDescription: String? {
            switch self {
            case .noDownloadId: return String(localized: "No download ID — item hasn't reached the client yet")
            case .downloadProtocolUnknown: return String(localized: "Unknown download protocol")
            case .downloadClientNotConfigured(let p):
                return String(localized: "Client (\(p.rawValue)) is not configured")
            }
        }
    }

    enum Action { case pause, resume, delete }

    private let configStore: ConfigStore
    private var cachedRadarrClient: RadarrClient?
    private var cachedRadarrConfig: ServiceConfig?
    private var cachedSonarrClient: SonarrClient?
    private var cachedSonarrConfig: ServiceConfig?
    private var cachedLidarrClient: LidarrClient?
    private var cachedLidarrConfig: ServiceConfig?
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
        let radarrClient = self.radarrClient(for: configStore.radarr)
        let sonarrClient = self.sonarrClient(for: configStore.sonarr)
        let lidarrClient = self.lidarrClient(for: configStore.lidarr)

        async let radarr = Self.safeFetch { try await radarrClient.fetchQueue() }
        async let sonarr = Self.safeFetch { try await sonarrClient.fetchQueue() }
        async let lidarr = Self.safeFetch { try await lidarrClient.fetchQueue() }
        let (r, s, l) = await (radarr, sonarr, lidarr)
        return AggregateResult(
            radarr: r.items, sonarr: s.items, lidarr: l.items,
            radarrError: r.error, sonarrError: s.error, lidarrError: l.error
        )
    }

    func fetchHealth() async -> HealthResult {
        let radarrCfg = configStore.radarr
        let sonarrCfg = configStore.sonarr
        let lidarrCfg = configStore.lidarr

        let radarrClient = self.radarrClient(for: radarrCfg)
        let sonarrClient = self.sonarrClient(for: sonarrCfg)
        let lidarrClient = self.lidarrClient(for: lidarrCfg)
        async let radarr = Self.safeFetchHealth { try await radarrClient.fetchHealth() }
        async let sonarr = Self.safeFetchHealth { try await sonarrClient.fetchHealth() }
        async let lidarr = Self.safeFetchHealth { try await lidarrClient.fetchHealth() }
        let (r, s, l) = await (radarr, sonarr, lidarr)
        return HealthResult(radarr: r, sonarr: s, lidarr: l)
    }

    private static func safeFetchHealth(_ block: () async throws -> [ArrHealthRecord]) async -> [ArrHealthRecord] {
        do { return try await block() } catch { return [] }
    }

    func fetchHistory(for source: QueueItem.Source) async -> HistoryResult {
        do {
            let items: [HistoryItem]
            switch source {
            case .radarr: items = try await radarrClient(for: configStore.radarr).fetchHistory()
            case .sonarr: items = try await sonarrClient(for: configStore.sonarr).fetchHistory()
            case .lidarr: items = try await lidarrClient(for: configStore.lidarr).fetchHistory()
            }
            return HistoryResult(items: items, error: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return HistoryResult(items: [], error: message)
        }
    }

    private func radarrClient(for cfg: ServiceConfig) -> RadarrClient {
        if let cached = cachedRadarrClient, cachedRadarrConfig == cfg { return cached }
        let client = RadarrClient(config: cfg)
        cachedRadarrClient = client
        cachedRadarrConfig = cfg
        return client
    }

    private func sonarrClient(for cfg: ServiceConfig) -> SonarrClient {
        if let cached = cachedSonarrClient, cachedSonarrConfig == cfg { return cached }
        let client = SonarrClient(config: cfg)
        cachedSonarrClient = client
        cachedSonarrConfig = cfg
        return client
    }

    private func lidarrClient(for cfg: ServiceConfig) -> LidarrClient {
        if let cached = cachedLidarrClient, cachedLidarrConfig == cfg { return cached }
        let client = LidarrClient(config: cfg)
        cachedLidarrClient = client
        cachedLidarrConfig = cfg
        return client
    }

    func fetchUpcoming() async -> [UpcomingItem] {
        let radarrCfg = configStore.radarr
        let sonarrCfg = configStore.sonarr
        let lidarrCfg = configStore.lidarr

        let radarrClient = self.radarrClient(for: radarrCfg)
        let sonarrClient = self.sonarrClient(for: sonarrCfg)
        let lidarrClient = self.lidarrClient(for: lidarrCfg)
        async let radarr = Self.safeFetchUpcoming { try await radarrClient.fetchCalendar() }
        async let sonarr = Self.safeFetchUpcoming { try await sonarrClient.fetchCalendar() }
        async let lidarr = Self.safeFetchUpcoming { try await lidarrClient.fetchCalendar() }
        let (r, s, l) = await (radarr, sonarr, lidarr)
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return (r + s + l)
            .filter { $0.airDate >= startOfToday }
            .sorted { $0.airDate < $1.airDate }
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
        // Delete is routed through the arr API — works for any download client.
        if action == .delete {
            try await deleteViaArr(item)
            return
        }

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

    private func deleteViaArr(_ item: QueueItem) async throws {
        switch item.source {
        case .radarr: try await radarrClient(for: configStore.radarr).deleteQueueItem(id: item.arrQueueId)
        case .sonarr: try await sonarrClient(for: configStore.sonarr).deleteQueueItem(id: item.arrQueueId)
        case .lidarr: try await lidarrClient(for: configStore.lidarr).deleteQueueItem(id: item.arrQueueId)
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

struct HistoryResult: Equatable {
    let items: [HistoryItem]
    let error: String?
}

struct HealthResult: Equatable {
    let radarr: [ArrHealthRecord]
    let sonarr: [ArrHealthRecord]
    let lidarr: [ArrHealthRecord]

    static let empty = HealthResult(radarr: [], sonarr: [], lidarr: [])
}

struct AggregateResult: Equatable {
    let radarr: [QueueItem]
    let sonarr: [QueueItem]
    let lidarr: [QueueItem]
    var radarrError: String?
    var sonarrError: String?
    var lidarrError: String?

    var totalCount: Int { radarr.count + sonarr.count + lidarr.count }
    var activeCount: Int {
        (radarr + sonarr + lidarr).filter { $0.status != .completed }.count
    }
}
