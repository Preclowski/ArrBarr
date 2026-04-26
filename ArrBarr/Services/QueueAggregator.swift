import Foundation

/// Pobiera kolejki z Radarr i Sonarr równolegle, a akcje (start/pauza/usuń) deleguje
/// do odpowiedniego klienta pobierającego (SAB/qBit) na podstawie `protocol` i `downloadId`.
///
/// Świadomie nie jest aktorem: zachowuje się jak prosta fasada, a izolację concurrency
/// zapewniają wewnątrz klienci API (każdy z nich to actor).
@MainActor
final class QueueAggregator {
    enum AggregateError: LocalizedError {
        case noDownloadId
        case downloadProtocolUnknown
        case downloadClientNotConfigured(QueueItem.DownloadProtocol)

        var errorDescription: String? {
            switch self {
            case .noDownloadId: return "Brak downloadId — pozycja jeszcze nie trafiła do klienta"
            case .downloadProtocolUnknown: return "Nieznany protokół pobierania"
            case .downloadClientNotConfigured(let p):
                return "Klient (\(p.rawValue)) nie jest skonfigurowany"
            }
        }
    }

    enum Action { case pause, resume, delete }

    private let configStore: ConfigStore

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    /// Pobiera kolejki Radarr + Sonarr równolegle. Błędy poszczególnych źródeł nie zatrzymują całości.
    func fetch() async -> AggregateResult {
        // Snapshot konfiguracji na main, potem network off-main.
        let radarrCfg = configStore.radarr
        let sonarrCfg = configStore.sonarr

        async let radarr: [QueueItem] = Self.safeFetch { try await RadarrClient(config: radarrCfg).fetchQueue() }
        async let sonarr: [QueueItem] = Self.safeFetch { try await SonarrClient(config: sonarrCfg).fetchQueue() }
        let (r, s) = await (radarr, sonarr)
        return AggregateResult(radarr: r, sonarr: s)
    }

    private static func safeFetch(_ block: () async throws -> [QueueItem]) async -> [QueueItem] {
        do { return try await block() } catch { return [] }
    }

    /// Wykonaj akcję na konkretnym elemencie kolejki, kierując ją do właściwego klienta.
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
            let qbit = QbittorrentClient(config: cfg)
            try await qbit.perform(qbitAction(action), hash: downloadId)

        case .unknown:
            throw AggregateError.downloadProtocolUnknown
        }
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

    var totalCount: Int { radarr.count + sonarr.count }
    var activeCount: Int {
        (radarr + sonarr).filter { $0.status != .completed }.count
    }
}
