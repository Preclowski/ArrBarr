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
        let lidarrCfg = configStore.lidarr
        let qbitCfg = configStore.qbittorrent
        let sabCfg = configStore.sabnzbd

        async let radarr = Self.safeFetch { try await RadarrClient(config: radarrCfg).fetchQueue() }
        async let sonarr = Self.safeFetch { try await SonarrClient(config: sonarrCfg).fetchQueue() }
        async let lidarr = Self.safeFetch { try await LidarrClient(config: lidarrCfg).fetchQueue() }
        async let qbitNames = Self.safeNames { qbitCfg.isConfigured ? try await self.qbitClient(for: qbitCfg).fetchNames() : [:] }
        async let sabNames = Self.safeNames {
            (sabCfg.isConfigured && !sabCfg.apiKey.isEmpty) ? try await SabnzbdClient(config: sabCfg).fetchNames() : [:]
        }
        let (r, s, l, qNames, sNames) = await (radarr, sonarr, lidarr, qbitNames, sabNames)
        return AggregateResult(
            radarr: Self.attachNames(r.items, torrents: qNames, usenet: sNames),
            sonarr: Self.attachNames(s.items, torrents: qNames, usenet: sNames),
            lidarr: Self.attachNames(l.items, torrents: qNames, usenet: sNames),
            radarrError: r.error, sonarrError: s.error, lidarrError: l.error
        )
    }

    private static func safeNames(_ block: () async throws -> [String: String]) async -> [String: String] {
        do { return try await block() } catch { return [:] }
    }

    private static func attachNames(_ items: [QueueItem], torrents: [String: String], usenet: [String: String]) -> [QueueItem] {
        items.map { item in
            guard let id = item.downloadId, !id.isEmpty else { return item }
            var copy = item
            switch item.downloadProtocol {
            case .torrent: copy.downloadFileName = torrents[id.lowercased()]
            case .usenet:  copy.downloadFileName = usenet[id]
            case .unknown: break
            }
            return copy
        }
    }

    func fetchHealth() async -> HealthResult {
        let radarrCfg = configStore.radarr
        let sonarrCfg = configStore.sonarr
        let lidarrCfg = configStore.lidarr

        async let radarr = Self.safeFetchHealth { try await RadarrClient(config: radarrCfg).fetchHealth() }
        async let sonarr = Self.safeFetchHealth { try await SonarrClient(config: sonarrCfg).fetchHealth() }
        async let lidarr = Self.safeFetchHealth { try await LidarrClient(config: lidarrCfg).fetchHealth() }
        let (r, s, l) = await (radarr, sonarr, lidarr)
        return HealthResult(radarr: r, sonarr: s, lidarr: l)
    }

    private static func safeFetchHealth(_ block: () async throws -> [ArrHealthRecord]) async -> [ArrHealthRecord] {
        do { return try await block() } catch { return [] }
    }

    func fetchUpcoming() async -> [UpcomingItem] {
        let radarrCfg = configStore.radarr
        let sonarrCfg = configStore.sonarr
        let lidarrCfg = configStore.lidarr

        async let radarr = Self.safeFetchUpcoming { try await RadarrClient(config: radarrCfg).fetchCalendar() }
        async let sonarr = Self.safeFetchUpcoming { try await SonarrClient(config: sonarrCfg).fetchCalendar() }
        async let lidarr = Self.safeFetchUpcoming { try await LidarrClient(config: lidarrCfg).fetchCalendar() }
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
