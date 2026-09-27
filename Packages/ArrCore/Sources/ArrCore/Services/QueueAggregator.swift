import Foundation
import MediaKit
import os

nonisolated public struct SourceQueueResult: Equatable {
    public let source: QueueItem.Source
    public let items: [QueueItem]
    public let error: String?
    public let unreachable: Bool
    public init(source: QueueItem.Source, items: [QueueItem], error: String?, unreachable: Bool) {
        self.source = source; self.items = items; self.error = error; self.unreachable = unreachable
    }
}

/// What `QueueViewModel` needs from the data layer; tests inject a fake.
protocol QueueDataProviding: Sendable {
    func fetch() async -> AggregateResult
    func fetch(source: QueueItem.Source) async -> SourceQueueResult
    func fetchUpcoming() async -> (items: [UpcomingItem], failed: Set<QueueItem.Source>)
    func fetchHealth() async -> HealthResult
    func fetchHistory(for source: QueueItem.Source, page: Int, pageSize: Int, entityId: Int?) async -> HistoryResult
    func perform(_ action: QueueAggregator.Action, on item: QueueItem) async throws
    func deleteAll(_ items: [QueueItem]) async throws
}

/// Queue, calendar, history and health for the four arrs plus the download-client progress overlay, all through MediaKit.
public final class QueueAggregator: QueueDataProviding, @unchecked Sendable {
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
    private let gateway: ServiceGateway
    private let progressLock = NSLock()
    private var progress: LiveStream<DownloadTask>?
    private var progressInstances: [InstanceID] = []
    private static let logger = Logger(category: "QueueFetch")

    @MainActor
    init(configStore: ConfigStore) {
        self.configStore = configStore
        self.gateway = configStore.gateway
    }

    // MARK: - Queue

    func fetch() async -> AggregateResult {
        let signpost = AppSignpost.queue
        let state = signpost.beginInterval("queue refresh")
        defer { signpost.endInterval("queue refresh", state) }
        var results: [QueueItem.Source: (items: [QueueItem], error: String?, unreachable: Bool)] = [:]
        await withTaskGroup(of: (QueueItem.Source, (items: [QueueItem], error: String?, unreachable: Bool)).self) { group in
            for source in QueueItem.Source.allCases { group.addTask { (source, await self.safeQueue(source)) } }
            for await (source, result) in group { results[source] = result }
        }
        let ids = Set(results.values.flatMap { $0.items.compactMap { $0.downloadId?.lowercased() }.filter { !$0.isEmpty } })
        let tasks = await progressSnapshot(ids: ids)
        var unreachable: Set<QueueItem.Source> = []
        for (source, r) in results where r.unreachable { unreachable.insert(source) }
        func slice(_ s: QueueItem.Source) -> [QueueItem] { Self.overlay(results[s]?.items ?? [], with: tasks) }
        return AggregateResult(
            radarr: slice(.radarr), sonarr: slice(.sonarr), lidarr: slice(.lidarr), whisparr: slice(.whisparr),
            radarrError: results[.radarr]?.error, sonarrError: results[.sonarr]?.error,
            lidarrError: results[.lidarr]?.error, whisparrError: results[.whisparr]?.error,
            unreachableSources: unreachable)
    }

    func fetch(source: QueueItem.Source) async -> SourceQueueResult {
        let outcome = await safeQueue(source)
        let ids = Set(outcome.items.compactMap { $0.downloadId?.lowercased() }.filter { !$0.isEmpty })
        let tasks = await progressSnapshot(ids: ids)
        return SourceQueueResult(source: source, items: Self.overlay(outcome.items, with: tasks), error: outcome.error, unreachable: outcome.unreachable)
    }

    private func safeQueue(_ source: QueueItem.Source) async -> (items: [QueueItem], error: String?, unreachable: Bool) {
        do {
            return (try await queueItems(source), nil, false)
        } catch is CancellationError {
            return ([], nil, false)
        } catch MediaKitError.notConfigured {
            return ([], nil, false)
        } catch {
            let message = MediaKitErrorPresenter.message(for: error)
            Self.logger.error("queue fetch failed: \(message, privacy: .public) | \(String(reflecting: error), privacy: .private)")
            return ([], message, MediaKitErrorPresenter.isUnreachable(error))
        }
    }

    private func queueItems(_ source: QueueItem.Source) async throws -> [QueueItem] {
        let baseURL = configStore.config(for: source.serviceKind).baseURL
        return try await ArrQueueLoader.items(source: source, gateway: gateway, baseURL: baseURL)
    }

    // MARK: - Download-client progress

    /// One live stream over the configured download clients; `staleGrace` keeps the bars steady across a blip.
    private func progressSnapshot(ids: Set<String>) async -> [String: DownloadTask] {
        guard !ids.isEmpty else { return [:] }
        let instances = await MainActor.run {
            MonitoredService.downloadClientKinds.filter { MonitoredService.arr($0).isConfigured(in: configStore) }.map(\.instanceID)
        }
        guard !instances.isEmpty else { return [:] }
        let stream = await liveProgress(instances: instances)
        await stream.setScope(.ids(ids))
        await stream.refreshNow(priority: .interactive)
        var out: [String: DownloadTask] = [:]
        for task in stream.last()?.elements ?? [] { out[task.id] = task }
        return out
    }

    private func liveProgress(instances: [InstanceID]) async -> LiveStream<DownloadTask> {
        let existing: LiveStream<DownloadTask>? = progressLock.withLock { progressInstances == instances ? progress : nil }
        if let existing { return existing }
        let stream = gateway.kit.liveProgress(instances: instances)
        progressLock.withLock { progress = stream; progressInstances = instances }
        return stream
    }

    nonisolated static func overlay(_ items: [QueueItem], with tasks: [String: DownloadTask]) -> [QueueItem] {
        guard !tasks.isEmpty else { return items }
        return items.map { item in
            guard let id = item.downloadId?.lowercased(), let task = tasks[id] else { return item }
            var copy = item
            copy.progress = task.progress
            if let speed = task.downloadSpeed { copy.downloadSpeed = speed }
            return copy
        }
    }

    // MARK: - Health, history, upcoming

    func fetchHealth() async -> HealthResult {
        await gateway.ready()
        var records: [QueueItem.Source: [ArrHealthRecord]] = [:]
        await withTaskGroup(of: (QueueItem.Source, [ArrHealthRecord]).self) { group in
            for source in QueueItem.Source.allCases {
                group.addTask {
                    guard self.gateway.isConfigured(source) else { return (source, []) }
                    let rows = (try? await self.gateway.store.read(self.gateway.servarr(source).health(), policy: .mustRevalidate).value) ?? []
                    return (source, rows.map { ArrHealthRecord(source: $0.source, type: $0.type, message: $0.message, wikiUrl: $0.wikiUrl) })
                }
            }
            for await (source, rows) in group { records[source] = rows }
        }
        return HealthResult(radarr: records[.radarr] ?? [], sonarr: records[.sonarr] ?? [], lidarr: records[.lidarr] ?? [], whisparr: records[.whisparr] ?? [])
    }

    func fetchHistory(for source: QueueItem.Source, page: Int, pageSize: Int, entityId: Int?) async -> HistoryResult {
        do {
            let baseURL = configStore.config(for: source.serviceKind).baseURL
            let result = try await ArrQueueLoader.history(source: source, gateway: gateway, baseURL: baseURL, page: page, pageSize: pageSize, entityId: entityId)
            return HistoryResult(items: result.items, hasMore: result.hasMore, error: nil)
        } catch {
            return HistoryResult(items: [], error: MediaKitErrorPresenter.message(for: error))
        }
    }

    func fetchUpcoming() async -> (items: [UpcomingItem], failed: Set<QueueItem.Source>) {
        var items: [UpcomingItem] = []
        var failed: Set<QueueItem.Source> = []
        await withTaskGroup(of: (QueueItem.Source, [UpcomingItem]?).self) { group in
            for source in QueueItem.Source.allCases {
                group.addTask {
                    let baseURL = await self.configStore.config(for: source.serviceKind).baseURL
                    do { return (source, try await ArrQueueLoader.upcoming(source: source, gateway: self.gateway, baseURL: baseURL)) }
                    catch MediaKitError.notConfigured { return (source, []) }
                    catch is CancellationError { return (source, []) }
                    catch { return (source, nil) }
                }
            }
            for await (source, rows) in group {
                if let rows { items += rows } else { failed.insert(source) }
            }
        }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return (items.filter { $0.airDate >= startOfToday }.sorted { $0.airDate < $1.airDate }, failed)
    }

    // MARK: - Actions

    func perform(_ action: Action, on item: QueueItem) async throws {
        if action == .delete {
            try await deleteViaArr(item, removeFromClient: true)
            return
        }
        if action == .continueDownload, (item.downloadId?.isEmpty ?? true) {
            _ = try await gateway.store.run(gateway.servarr(item.source).grabQueueItem(id: item.arrQueueId))
            return
        }
        guard let downloadId = item.downloadId, !downloadId.isEmpty else { throw AggregateError.noDownloadId }
        guard item.downloadProtocol != .unknown else { throw AggregateError.downloadProtocolUnknown }
        let configured = await MainActor.run {
            Self.candidateKinds(for: item.downloadProtocol).filter { MonitoredService.arr($0).isConfigured(in: configStore) }
        }
        guard let kind = Self.route(clientNamed: item.downloadClient, among: configured),
              let service = gateway.download(kind) else {
            throw AggregateError.downloadClientNotConfigured(item.downloadProtocol)
        }
        let clientAction: DownloadAction = switch action {
        case .pause: .pause
        case .resume: .resume
        case .continueDownload: .forceStart
        case .delete: .delete
        }
        _ = try await gateway.store.run(service.action(clientAction, ids: [downloadId], deleteFiles: false))
    }

    private func deleteViaArr(_ item: QueueItem, removeFromClient: Bool) async throws {
        let service = gateway.servarr(item.source)
        _ = try await gateway.store.run(service.deleteQueueItem(id: item.arrQueueId, removeFromClient: removeFromClient, blocklist: false, now: Date()))
    }

    func deleteAll(_ items: [QueueItem]) async throws {
        let downloadIds = Set(items.compactMap { $0.downloadId?.isEmpty == false ? $0.downloadId : nil })
        let sharedDownload = downloadIds.count <= 1
        var first = true
        for item in items {
            try await deleteViaArr(item, removeFromClient: sharedDownload ? first : true)
            first = false
        }
    }

    nonisolated static func candidateKinds(for proto: QueueItem.DownloadProtocol) -> [ServiceKind] {
        switch proto {
        case .usenet: return [.sabnzbd, .nzbget]
        case .torrent: return [.qbittorrent, .transmission, .rtorrent, .deluge]
        case .unknown: return []
        }
    }

    /// The arr names the client it used; match that name among the configured ones before falling back to the first.
    nonisolated static func route(clientNamed name: String?, among configured: [ServiceKind]) -> ServiceKind? {
        guard let fallback = configured.first else { return nil }
        guard configured.count > 1 else { return fallback }
        let needle = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return fallback }
        if let exact = configured.first(where: { $0.displayName.lowercased() == needle }) { return exact }
        if let fuzzy = configured.first(where: { kind in nameTokens(kind).contains { needle.contains($0) } }) { return fuzzy }
        return fallback
    }

    private nonisolated static func nameTokens(_ kind: ServiceKind) -> [String] {
        switch kind {
        case .sabnzbd: return ["sabnzbd", "sab"]
        case .nzbget: return ["nzbget"]
        case .qbittorrent: return ["qbittorrent", "qbit"]
        case .transmission: return ["transmission"]
        case .rtorrent: return ["rtorrent", "rutorrent"]
        case .deluge: return ["deluge"]
        case .radarr, .sonarr, .lidarr, .whisparr: return []
        }
    }
}

nonisolated public struct HistoryResult: Equatable {
    public let items: [HistoryItem]
    public let hasMore: Bool
    public let error: String?
    public init(items: [HistoryItem], hasMore: Bool = false, error: String?) {
        self.items = items; self.hasMore = hasMore; self.error = error
    }
}

nonisolated public struct HealthResult: Equatable {
    public let radarr: [ArrHealthRecord]
    public let sonarr: [ArrHealthRecord]
    public let lidarr: [ArrHealthRecord]
    public let whisparr: [ArrHealthRecord]
    public init(radarr: [ArrHealthRecord], sonarr: [ArrHealthRecord], lidarr: [ArrHealthRecord], whisparr: [ArrHealthRecord] = []) {
        self.radarr = radarr; self.sonarr = sonarr; self.lidarr = lidarr; self.whisparr = whisparr
    }
    public static let empty = HealthResult(radarr: [], sonarr: [], lidarr: [], whisparr: [])
    public func records(for source: QueueItem.Source) -> [ArrHealthRecord] {
        switch source {
        case .radarr: radarr
        case .sonarr: sonarr
        case .lidarr: lidarr
        case .whisparr: whisparr
        }
    }
}

nonisolated public struct AggregateResult: Equatable {
    public let radarr: [QueueItem]
    public let sonarr: [QueueItem]
    public let lidarr: [QueueItem]
    public let whisparr: [QueueItem]
    public let radarrError: String?
    public let sonarrError: String?
    public let lidarrError: String?
    public let whisparrError: String?
    public let unreachableSources: Set<QueueItem.Source>

    func slice(for source: QueueItem.Source) -> SourceQueueResult {
        switch source {
        case .radarr: SourceQueueResult(source: source, items: radarr, error: radarrError, unreachable: unreachableSources.contains(source))
        case .sonarr: SourceQueueResult(source: source, items: sonarr, error: sonarrError, unreachable: unreachableSources.contains(source))
        case .lidarr: SourceQueueResult(source: source, items: lidarr, error: lidarrError, unreachable: unreachableSources.contains(source))
        case .whisparr: SourceQueueResult(source: source, items: whisparr, error: whisparrError, unreachable: unreachableSources.contains(source))
        }
    }

    init(radarr: [QueueItem], sonarr: [QueueItem], lidarr: [QueueItem], whisparr: [QueueItem] = [],
         radarrError: String? = nil, sonarrError: String? = nil, lidarrError: String? = nil, whisparrError: String? = nil,
         unreachableSources: Set<QueueItem.Source> = []) {
        self.radarr = radarr; self.sonarr = sonarr; self.lidarr = lidarr; self.whisparr = whisparr
        self.radarrError = radarrError; self.sonarrError = sonarrError; self.lidarrError = lidarrError; self.whisparrError = whisparrError
        self.unreachableSources = unreachableSources
    }
}
