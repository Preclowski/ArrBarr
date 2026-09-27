import Foundation
import MediaKit
import os

/// A live stream revision tied to the stream that published it: a replaced stream counts from zero again.
nonisolated public struct QueueRevision: Equatable, Sendable {
    let stream: ObjectIdentifier
    let number: UInt64

    /// Already committed: the same stream, at or past this number.
    func isCovered(by committed: QueueRevision?) -> Bool {
        committed.map { $0.stream == stream && number <= $0.number } ?? false
    }
}

nonisolated public struct SourceQueueResult: Equatable {
    public let source: QueueItem.Source
    public let items: [QueueItem]
    public let error: String?
    public let unreachable: Bool
    /// When the arr answered the rows; nil when nothing was measured (a failure, an unconfigured arr, a test fake).
    public let measuredAt: Date?
    /// The live stream revision behind this result, so the same fetch is never committed twice; nil commits always.
    public let revision: QueueRevision?
    public init(source: QueueItem.Source, items: [QueueItem], error: String?, unreachable: Bool, measuredAt: Date? = nil, revision: QueueRevision? = nil) {
        self.source = source; self.items = items; self.error = error; self.unreachable = unreachable
        self.measuredAt = measuredAt; self.revision = revision
    }
}

/// What `QueueViewModel` needs from the data layer; tests inject a fake.
protocol QueueDataProviding: Sendable {
    func fetch() async -> AggregateResult
    func fetch(source: QueueItem.Source) async -> SourceQueueResult
    /// What the source's live stream last published, composed without asking the arr.
    func latest(source: QueueItem.Source) async -> SourceQueueResult
    /// The revision `latest(source:)` would compose, read without composing; nil when there is no stream.
    func latestRevision(source: QueueItem.Source) -> QueueRevision?
    func fetchUpcoming() async -> (items: [UpcomingItem], failed: Set<QueueItem.Source>)
    func fetchHealth() async -> HealthResult
    func fetchHistory(for source: QueueItem.Source, page: Int, pageSize: Int, entityId: Int?) async -> HistoryResult
    func perform(_ action: QueueAggregator.Action, on item: QueueItem) async throws
    func deleteAll(_ items: [QueueItem]) async throws
}

extension QueueDataProviding {
    func latest(source: QueueItem.Source) async -> SourceQueueResult { await fetch(source: source) }
    func latestRevision(source: QueueItem.Source) -> QueueRevision? { nil }
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
        var results: [QueueItem.Source: QueueOutcome] = [:]
        await withTaskGroup(of: (QueueItem.Source, QueueOutcome).self) { group in
            for source in QueueItem.Source.allCases { group.addTask { (source, await self.safeQueue(source)) } }
            for await (source, result) in group { results[source] = result }
        }
        var bySource: [QueueItem.Source: Set<String>] = [:]
        for (source, r) in results { bySource[source] = Self.downloadIDs(r.items) }
        let tasks = await progressSnapshot(ids: bySource, reuse: false)
        var unreachable: Set<QueueItem.Source> = []
        for (source, r) in results where r.unreachable { unreachable.insert(source) }
        func slice(_ s: QueueItem.Source) -> [QueueItem] { Self.overlay(results[s]?.items ?? [], with: tasks) }
        return AggregateResult(
            radarr: slice(.radarr), sonarr: slice(.sonarr), lidarr: slice(.lidarr), whisparr: slice(.whisparr),
            radarrError: results[.radarr]?.error, sonarrError: results[.sonarr]?.error,
            lidarrError: results[.lidarr]?.error, whisparrError: results[.whisparr]?.error,
            unreachableSources: unreachable,
            measuredAt: results.compactMapValues(\.measuredAt), revision: results.compactMapValues(\.revision))
    }

    func fetch(source: QueueItem.Source) async -> SourceQueueResult {
        await result(source, refresh: true)
    }

    func latest(source: QueueItem.Source) async -> SourceQueueResult {
        await result(source, refresh: false)
    }

    func latestRevision(source: QueueItem.Source) -> QueueRevision? {
        let stream = gateway.queueStream(source)
        return stream.last().map { QueueRevision(stream: ObjectIdentifier(stream), number: $0.revision) }
    }

    private func result(_ source: QueueItem.Source, refresh: Bool) async -> SourceQueueResult {
        let outcome = await safeQueue(source, refresh: refresh)
        let tasks = await progressSnapshot(ids: [source: Self.downloadIDs(outcome.items)], reuse: !refresh)
        return SourceQueueResult(source: source, items: Self.overlay(outcome.items, with: tasks), error: outcome.error,
                                 unreachable: outcome.unreachable, measuredAt: outcome.measuredAt, revision: outcome.revision)
    }

    private typealias QueueOutcome = (items: [QueueItem], error: String?, unreachable: Bool, measuredAt: Date?, revision: QueueRevision?)

    private func safeQueue(_ source: QueueItem.Source, refresh: Bool = true) async -> QueueOutcome {
        do {
            let read = try await queueItems(source, refresh: refresh)
            return (read.items, nil, false, read.measuredAt, read.revision)
        } catch {
            let revision = (error as? ArrQueueLoader.LiveFailure)?.revision
            let error = (error as? ArrQueueLoader.LiveFailure)?.underlying ?? error
            if error is CancellationError { return ([], nil, false, nil, nil) }
            if case MediaKitError.notConfigured = error { return ([], nil, false, nil, revision) }
            let message = MediaKitErrorPresenter.message(for: error)
            // The message carries the host and the server's own text; only the case is public.
            let kind = (error as? MediaKitError)?.caseName ?? String(describing: type(of: error))
            Self.logger.error("queue fetch failed: \(kind, privacy: .public) | \(message, privacy: .private)")
            return ([], message, MediaKitErrorPresenter.isUnreachable(error), nil, revision)
        }
    }

    private func queueItems(_ source: QueueItem.Source, refresh: Bool) async throws -> ArrQueueLoader.Measured {
        let baseURL = configStore.config(for: source.serviceKind).baseURL
        return try await ArrQueueLoader.measuredItems(source: source, gateway: gateway, baseURL: baseURL, refresh: refresh)
    }

    // MARK: - Download-client progress

    /// One live stream over the configured download clients; `staleGrace` keeps the bars steady across a blip.
    /// Every arr's download ids, so one progress fetch serves all of them.
    private let progressIDs = OSAllocatedUnfairLock<[QueueItem.Source: Set<String>]>(initialState: [:])
    /// The queue streams publish per arr within moments of each other; one reading serves the lot.
    private static let progressReuseWindow: TimeInterval = 2

    private static func downloadIDs(_ items: [QueueItem]) -> Set<String> {
        Set(items.compactMap { $0.downloadId?.lowercased() }.filter { !$0.isEmpty })
    }

    /// `reuse` answers from a reading younger than `progressReuseWindow` that already covers these ids.
    private func progressSnapshot(ids: [QueueItem.Source: Set<String>], reuse: Bool) async -> [String: DownloadTask] {
        let union = progressIDs.withLock { known -> Set<String> in
            known.merge(ids) { $1 }
            return known.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        }
        let wanted = ids.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard !wanted.isEmpty else { return [:] }
        let instances = await MainActor.run {
            MonitoredService.downloadClientKinds.filter { MonitoredService.arr($0).isConfigured(in: configStore) }.map(\.instanceID)
        }
        guard !instances.isEmpty else { return [:] }
        let stream = gateway.progressStream(instances: instances)
        let covered = stream.last().map { value in
            Date().timeIntervalSince(value.measuredAt) < Self.progressReuseWindow
                && wanted.isSubset(of: Set(value.elements.map { $0.id.lowercased() }))
        } ?? false
        if !(reuse && covered) {
            await stream.setScope(.ids(union))
            await stream.refreshNow(priority: .interactive)
        }
        var out: [String: DownloadTask] = [:]
        for task in stream.last()?.elements ?? [] { out[task.id] = task }
        return out
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
        var records: [QueueItem.Source: [ArrHealth]] = [:]
        await withTaskGroup(of: (QueueItem.Source, [ArrHealth]).self) { group in
            for source in QueueItem.Source.allCases {
                group.addTask {
                    guard self.gateway.isConfigured(source) else { return (source, []) }
                    let rows = (try? await self.gateway.store.read(self.gateway.servarr(source).health(), policy: .mustRevalidate).value) ?? []
                    return (source, rows)
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
        return (UpcomingService.curate(items), failed)
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
    public let radarr: [ArrHealth]
    public let sonarr: [ArrHealth]
    public let lidarr: [ArrHealth]
    public let whisparr: [ArrHealth]
    public init(radarr: [ArrHealth], sonarr: [ArrHealth], lidarr: [ArrHealth], whisparr: [ArrHealth] = []) {
        self.radarr = radarr; self.sonarr = sonarr; self.lidarr = lidarr; self.whisparr = whisparr
    }
    public static let empty = HealthResult(radarr: [], sonarr: [], lidarr: [], whisparr: [])
    public func records(for source: QueueItem.Source) -> [ArrHealth] {
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
    public let measuredAt: [QueueItem.Source: Date]
    public let revision: [QueueItem.Source: QueueRevision]

    func slice(for source: QueueItem.Source) -> SourceQueueResult {
        let (items, error): ([QueueItem], String?) = switch source {
        case .radarr: (radarr, radarrError)
        case .sonarr: (sonarr, sonarrError)
        case .lidarr: (lidarr, lidarrError)
        case .whisparr: (whisparr, whisparrError)
        }
        return SourceQueueResult(source: source, items: items, error: error, unreachable: unreachableSources.contains(source),
                                 measuredAt: measuredAt[source], revision: revision[source])
    }

    init(radarr: [QueueItem], sonarr: [QueueItem], lidarr: [QueueItem], whisparr: [QueueItem] = [],
         radarrError: String? = nil, sonarrError: String? = nil, lidarrError: String? = nil, whisparrError: String? = nil,
         unreachableSources: Set<QueueItem.Source> = [], measuredAt: [QueueItem.Source: Date] = [:],
         revision: [QueueItem.Source: QueueRevision] = [:]) {
        self.radarr = radarr; self.sonarr = sonarr; self.lidarr = lidarr; self.whisparr = whisparr
        self.radarrError = radarrError; self.sonarrError = sonarrError; self.lidarrError = lidarrError; self.whisparrError = whisparrError
        self.unreachableSources = unreachableSources
        self.measuredAt = measuredAt
        self.revision = revision
    }
}
