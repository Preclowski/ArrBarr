import Foundation
import os

/// The slice of `QueueAggregator` that `QueueViewModel` depends on. Extracted
/// as a protocol purely so the view-model can be driven by a fake in tests —
/// production always wires the concrete `QueueAggregator`.
@MainActor
protocol QueueDataProviding {
    func fetch() async -> AggregateResult
    func fetchUpcoming() async -> (items: [UpcomingItem], failed: Set<QueueItem.Source>)
    func fetchHealth() async -> HealthResult
    func fetchHistory(for source: QueueItem.Source) async -> HistoryResult
    func perform(_ action: QueueAggregator.Action, on item: QueueItem) async throws
    func deleteAll(_ items: [QueueItem]) async throws
}

@MainActor
public final class QueueAggregator: QueueDataProviding {
    enum AggregateError: LocalizedError {
        case noDownloadId
        case downloadProtocolUnknown
        case downloadClientNotConfigured(QueueItem.DownloadProtocol)

        var errorDescription: String? {
            switch self {
            case .noDownloadId: return String(localized: "queue.noDownloadIdItem.tooltip", bundle: .module)
            case .downloadProtocolUnknown: return String(localized: "queue.unknownDownloadProtocol.label", bundle: .module)
            case .downloadClientNotConfigured(let p):
                return String(format: String(localized: "common.clientIsNotConfigured.label", bundle: .module), p.rawValue)
            }
        }
    }

    enum Action { case pause, resume, delete, continueDownload }

    private let configStore: ConfigStore
    private var cachedRadarrClient: RadarrClient?
    private var cachedRadarrConfig: ServiceConfig?
    private var cachedSonarrClient: SonarrClient?
    private var cachedSonarrConfig: ServiceConfig?
    private var cachedLidarrClient: LidarrClient?
    private var cachedLidarrConfig: ServiceConfig?
    private var cachedWhisparrClient: WhisparrClient?
    private var cachedWhisparrConfig: ServiceConfig?
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
        let whisparrClient = self.whisparrClient(for: configStore.whisparr)

        async let radarr = Self.safeFetch { try await radarrClient.fetchQueue() }
        async let sonarr = Self.safeFetch { try await sonarrClient.fetchQueue() }
        async let lidarr = Self.safeFetch { try await lidarrClient.fetchQueue() }
        async let whisparr = Self.safeFetch { try await whisparrClient.fetchQueue() }
        let (r, s, l, w) = await (radarr, sonarr, lidarr, whisparr)
        // Only *transport-level* failures (no response from the host) count as
        // unreachable — an HTTP 502/500/401 means the server answered, so it's
        // a service problem, not "we've left the LAN". This is what keeps the
        // offline indicator from firing on an outage.
        var unreachable: Set<QueueItem.Source> = []
        if r.unreachable { unreachable.insert(.radarr) }
        if s.unreachable { unreachable.insert(.sonarr) }
        if l.unreachable { unreachable.insert(.lidarr) }
        if w.unreachable { unreachable.insert(.whisparr) }
        // Overlay live progress from the download clients on top of the arr's
        // polled `/queue` value — the arr stays the fallback (no client / no
        // match / client unreachable). Cached + batched in DownloadProgressService.
        let clientProgress = await DownloadProgressService.shared.snapshot(configs: downloadClientConfigs())
        return AggregateResult(
            radarr: Self.overlay(r.items, with: clientProgress),
            sonarr: Self.overlay(s.items, with: clientProgress),
            lidarr: Self.overlay(l.items, with: clientProgress),
            whisparr: Self.overlay(w.items, with: clientProgress),
            radarrError: r.error, sonarrError: s.error, lidarrError: l.error, whisparrError: w.error,
            unreachableSources: unreachable
        )
    }

    /// Configs for every download-client kind, handed to `DownloadProgressService`
    /// (which builds + caches the source clients and never re-logs in needlessly).
    private func downloadClientConfigs() -> [ServiceKind: ServiceConfig] {
        var configs: [ServiceKind: ServiceConfig] = [:]
        for kind in MonitoredService.downloadClientKinds {
            configs[kind] = configStore.config(for: kind)
        }
        return configs
    }

    /// Replace each item's arr-polled progress with the client's live value when
    /// we have it (matched by lowercased download id); no match keeps the arr value.
    /// `internal` + `nonisolated` (not private/MainActor) so it's unit-testable
    /// as the pure function it is — it touches no aggregator state.
    nonisolated static func overlay(_ items: [QueueItem], with progress: [String: DownloadProgress]) -> [QueueItem] {
        guard !progress.isEmpty else { return items }
        return items.map { item in
            guard let id = item.downloadId?.lowercased(), let p = progress[id] else { return item }
            var copy = item
            copy.progress = p.progress
            return copy
        }
    }

    func fetchHealth() async -> HealthResult {
        let radarrCfg = configStore.radarr
        let sonarrCfg = configStore.sonarr
        let lidarrCfg = configStore.lidarr
        let whisparrCfg = configStore.whisparr

        let radarrClient = self.radarrClient(for: radarrCfg)
        let sonarrClient = self.sonarrClient(for: sonarrCfg)
        let lidarrClient = self.lidarrClient(for: lidarrCfg)
        let whisparrClient = self.whisparrClient(for: whisparrCfg)
        async let radarr = Self.safeFetchHealth { try await radarrClient.fetchHealth() }
        async let sonarr = Self.safeFetchHealth { try await sonarrClient.fetchHealth() }
        async let lidarr = Self.safeFetchHealth { try await lidarrClient.fetchHealth() }
        async let whisparr = Self.safeFetchHealth { try await whisparrClient.fetchHealth() }
        let (r, s, l, w) = await (radarr, sonarr, lidarr, whisparr)
        return HealthResult(radarr: r, sonarr: s, lidarr: l, whisparr: w)
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
            case .whisparr: items = try await whisparrClient(for: configStore.whisparr).fetchHistory()
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

    private func whisparrClient(for cfg: ServiceConfig) -> WhisparrClient {
        if let cached = cachedWhisparrClient, cachedWhisparrConfig == cfg { return cached }
        let client = WhisparrClient(config: cfg)
        cachedWhisparrClient = client
        cachedWhisparrConfig = cfg
        return client
    }

    func fetchUpcoming() async -> (items: [UpcomingItem], failed: Set<QueueItem.Source>) {
        let radarrCfg = configStore.radarr
        let sonarrCfg = configStore.sonarr
        let lidarrCfg = configStore.lidarr
        let whisparrCfg = configStore.whisparr

        let radarrClient = self.radarrClient(for: radarrCfg)
        let sonarrClient = self.sonarrClient(for: sonarrCfg)
        let lidarrClient = self.lidarrClient(for: lidarrCfg)
        let whisparrClient = self.whisparrClient(for: whisparrCfg)
        async let radarr = Self.safeFetchUpcoming { try await radarrClient.fetchCalendar() }
        async let sonarr = Self.safeFetchUpcoming { try await sonarrClient.fetchCalendar() }
        async let lidarr = Self.safeFetchUpcoming { try await lidarrClient.fetchCalendar() }
        async let whisparr = Self.safeFetchUpcoming { try await whisparrClient.fetchCalendar() }
        let (r, s, l, w) = await (radarr, sonarr, lidarr, whisparr)
        var failed: Set<QueueItem.Source> = []
        if r.failed { failed.insert(.radarr) }
        if s.failed { failed.insert(.sonarr) }
        if l.failed { failed.insert(.lidarr) }
        if w.failed { failed.insert(.whisparr) }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let items = (r.items + s.items + l.items + w.items)
            .filter { $0.airDate >= startOfToday }
            .sorted { $0.airDate < $1.airDate }
        return (items, failed)
    }

    private static func safeFetch(_ block: () async throws -> [QueueItem]) async -> (items: [QueueItem], error: String?, unreachable: Bool) {
        do {
            return (try await block(), nil, false)
        } catch is CancellationError {
            // Refresh task was cancelled (e.g. user released pull-to-refresh,
            // or an overlapping refresh superseded this one). Not a real
            // failure — return no error so the caller keeps the last good data.
            return ([], nil, false)
        } catch let error as URLError where error.code == .cancelled {
            // URLSession's cancellation variant (code -999) — same story.
            return ([], nil, false)
        } catch HTTPError.notConfigured, HTTPError.missingApiKey {
            // The arr isn't set up — not a failure to surface. `fetchUpcoming`
            // and `fetchHealth` already swallow these; the queue must too,
            // otherwise an unconfigured Lidarr/Whisparr shows "Service not
            // configured" in the queue while Upcoming (which swallows it)
            // looks fine. Settings is where missing config/keys are reported.
            return ([], nil, false)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Genuine failure (HTTP status, transport/timeout, decode). Log the
            // full reflection — a DecodingError's coding path or a URLError's
            // numeric code — since the UI string drops it. Keep it `.private`,
            // though: a URLError embeds its failing URL, and for SABnzbd that
            // URL carries `apikey=` in the query, which must not land in the
            // public unified-log. `message` stays public (it's sanitized).
            Self.logger.error("queue fetch failed: \(message, privacy: .public) | \(String(reflecting: error), privacy: .private)")
            return ([], message, Self.isUnreachable(error))
        }
    }

    /// Distinguishes "couldn't reach the arr" from "the arr itself answered
    /// with an error". Only the former feeds the offline indicator.
    ///
    /// Subtlety that bit us: a status code alone can't always tell the two
    /// apart, because a reverse proxy / split-horizon-DNS endpoint sits in
    /// front. So we split by *who* produced the failure:
    ///  • Transport failure (no route / refused / DNS / timeout) → unreachable.
    ///  • Gateway statuses (502/503/504, Cloudflare 52x) and 404/410 → a proxy
    ///    or the wrong endpoint answered, NOT the arr (a real arr never 404s
    ///    its own `/api/v3/queue`) → unreachable. This is the away-behind-
    ///    split-DNS case.
    ///  • Arr-origin statuses (500 it threw, 401/403 bad key, 400/422 bad
    ///    request) prove we're actually talking to the arr → reachable; those
    ///    stay a "service problem" (and point the user at Settings/the arr).
    nonisolated static func isUnreachable(_ error: Error) -> Bool {
        switch error {
        case HTTPError.transport(let inner):
            return isConnectivityFailure(inner)
        case HTTPError.status(let code, _):
            // 408 request timeout, 404/410 wrong endpoint, 502/503/504 gateway,
            // 522/523/524 Cloudflare — none come from the arr answering its own
            // API, so treat as "couldn't reach the arr".
            switch code {
            case 404, 408, 410, 502, 503, 504, 522, 523, 524:
                return true
            default:
                return false
            }
        case let urlError as URLError:
            return isConnectivityFailure(urlError)
        default:
            // HTTPError.decoding / .badURL etc. → local failure, not a reach
            // signal either way.
            return false
        }
    }

    nonisolated static func isConnectivityFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .timedOut, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            // e.g. .secureConnectionFailed means the TLS handshake started —
            // the host was reached — so that's not an unreachable signal.
            return false
        }
    }

    private static let logger = Logger(category: "QueueFetch")

    private static func safeFetchUpcoming(_ block: () async throws -> [UpcomingItem]) async -> (items: [UpcomingItem], failed: Bool) {
        do {
            return (try await block(), false)
        } catch HTTPError.notConfigured, HTTPError.missingApiKey {
            // Not set up → genuinely empty, nothing to preserve.
            return ([], false)
        } catch is CancellationError {
            return ([], false)
        } catch let error as URLError where error.code == .cancelled {
            return ([], false)
        } catch {
            // Real failure (transport / HTTP / decode). Flag it so the caller
            // keeps this source's last-known calendar instead of dropping it —
            // otherwise a blocked Radarr silently erases its movies from a
            // merged "Upcoming".
            return ([], true)
        }
    }

    func perform(_ action: Action, on item: QueueItem) async throws {
        // Delete is routed through the arr API — works for any download client.
        if action == .delete {
            try await deleteViaArr(item)
            return
        }

        // A deferred item the arr is still holding (delay profile) has no
        // download-client entry yet, so "continue" can't go through the client —
        // force-grab it via the arr API instead (POST /queue/grab/{id}).
        if action == .continueDownload, (item.downloadId?.isEmpty ?? true) {
            try await grabViaArr(item)
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
        try await deleteViaArr(item, removeFromClient: true)
    }

    private func deleteViaArr(_ item: QueueItem, removeFromClient: Bool) async throws {
        switch item.source {
        case .radarr: try await radarrClient(for: configStore.radarr).deleteQueueItem(id: item.arrQueueId, removeFromClient: removeFromClient)
        case .sonarr: try await sonarrClient(for: configStore.sonarr).deleteQueueItem(id: item.arrQueueId, removeFromClient: removeFromClient)
        case .lidarr: try await lidarrClient(for: configStore.lidarr).deleteQueueItem(id: item.arrQueueId, removeFromClient: removeFromClient)
        case .whisparr: try await whisparrClient(for: configStore.whisparr).deleteQueueItem(id: item.arrQueueId, removeFromClient: removeFromClient)
        }
    }

    private func grabViaArr(_ item: QueueItem) async throws {
        switch item.source {
        case .radarr: try await radarrClient(for: configStore.radarr).grabQueueItem(id: item.arrQueueId)
        case .sonarr: try await sonarrClient(for: configStore.sonarr).grabQueueItem(id: item.arrQueueId)
        case .lidarr: try await lidarrClient(for: configStore.lidarr).grabQueueItem(id: item.arrQueueId)
        case .whisparr: try await whisparrClient(for: configStore.whisparr).grabQueueItem(id: item.arrQueueId)
        }
    }

    /// Removes every member of a grouped row from the arr queue.
    ///
    /// Two cases share this entry point:
    ///   - **Real season pack** — all members share one `downloadId`. The
    ///     first call sets `removeFromClient: true` (that single call
    ///     removes the physical download); the rest just clean up sibling
    ///     queue rows so the popover doesn't leave them orphaned for ~30s
    ///     while Sonarr's queue GC catches up.
    ///   - **Virtual season bundle** — members have distinct `downloadId`s,
    ///     each backing its own download. Every call must set
    ///     `removeFromClient: true` so every torrent/nzb is removed.
    ///
    /// The two cases are distinguished by whether all members share the
    /// same non-empty downloadId.
    func deleteAll(_ items: [QueueItem]) async throws {
        let downloadIds = Set(items.compactMap { $0.downloadId?.isEmpty == false ? $0.downloadId : nil })
        let sharedDownload = downloadIds.count <= 1
        var first = true
        for item in items {
            let removeFromClient = sharedDownload ? first : true
            try await deleteViaArr(item, removeFromClient: removeFromClient)
            first = false
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

    // `.continueDownload` maps to qBittorrent's force-start (bypass the queue +
    // begin downloading). The other clients have no distinct force-start, so it
    // falls back to a plain resume — still the right intent ("start this now").
    private func sabAction(_ a: Action) -> SabnzbdClient.Action {
        switch a { case .pause: .pause; case .resume, .continueDownload: .resume; case .delete: .delete }
    }

    private func qbitAction(_ a: Action) -> QbittorrentClient.Action {
        switch a { case .pause: .pause; case .resume: .resume; case .delete: .delete; case .continueDownload: .forceStart }
    }

    private func nzbgetAction(_ a: Action) -> NzbgetClient.Action {
        switch a { case .pause: .pause; case .resume, .continueDownload: .resume; case .delete: .delete }
    }

    private func transmissionAction(_ a: Action) -> TransmissionClient.Action {
        switch a { case .pause: .pause; case .resume, .continueDownload: .resume; case .delete: .delete }
    }

    private func rtorrentAction(_ a: Action) -> RtorrentClient.Action {
        switch a { case .pause: .pause; case .resume, .continueDownload: .resume; case .delete: .delete }
    }

    private func delugeAction(_ a: Action) -> DelugeClient.Action {
        switch a { case .pause: .pause; case .resume, .continueDownload: .resume; case .delete: .delete }
    }
}

public struct HistoryResult: Equatable {
    public let items: [HistoryItem]
    public let error: String?
    public init(items: [HistoryItem], error: String?) {
        self.items = items; self.error = error
    }
}

public struct HealthResult: Equatable {
    public let radarr: [ArrHealthRecord]
    public let sonarr: [ArrHealthRecord]
    public let lidarr: [ArrHealthRecord]
    public let whisparr: [ArrHealthRecord]
    public init(radarr: [ArrHealthRecord], sonarr: [ArrHealthRecord], lidarr: [ArrHealthRecord],
                whisparr: [ArrHealthRecord] = []) {
        self.radarr = radarr; self.sonarr = sonarr; self.lidarr = lidarr; self.whisparr = whisparr
    }
    public static let empty = HealthResult(radarr: [], sonarr: [], lidarr: [], whisparr: [])

    public func records(for source: QueueItem.Source) -> [ArrHealthRecord] {
        switch source {
        case .radarr:   return radarr
        case .sonarr:   return sonarr
        case .lidarr:   return lidarr
        case .whisparr: return whisparr
        }
    }
}

public struct AggregateResult: Equatable {
    let radarr: [QueueItem]
    let sonarr: [QueueItem]
    let lidarr: [QueueItem]
    let whisparr: [QueueItem]
    var radarrError: String?
    var sonarrError: String?
    var lidarrError: String?
    var whisparrError: String?
    /// Sources that failed at the transport level this fetch (host unreachable),
    /// as opposed to those that answered with an HTTP/decode error. Drives the
    /// offline indicator; empty for a healthy or merely outaged stack.
    var unreachableSources: Set<QueueItem.Source>

    init(radarr: [QueueItem], sonarr: [QueueItem], lidarr: [QueueItem], whisparr: [QueueItem] = [],
         radarrError: String? = nil, sonarrError: String? = nil, lidarrError: String? = nil,
         whisparrError: String? = nil, unreachableSources: Set<QueueItem.Source> = []) {
        self.radarr = radarr; self.sonarr = sonarr; self.lidarr = lidarr; self.whisparr = whisparr
        self.radarrError = radarrError; self.sonarrError = sonarrError; self.lidarrError = lidarrError
        self.whisparrError = whisparrError
        self.unreachableSources = unreachableSources
    }

    var totalCount: Int { radarr.count + sonarr.count + lidarr.count + whisparr.count }
    var activeCount: Int {
        (radarr + sonarr + lidarr + whisparr).filter { $0.status != .completed }.count
    }
}
