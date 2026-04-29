import Foundation
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class QueueViewModel: ObservableObject {
    @Published private(set) var radarr: [QueueItem] = []
    @Published private(set) var sonarr: [QueueItem] = []
    @Published private(set) var lidarr: [QueueItem] = []
    @Published private(set) var radarrError: String?
    @Published private(set) var sonarrError: String?
    @Published private(set) var lidarrError: String?
    @Published private(set) var upcoming: [UpcomingItem] = []
    @Published private(set) var health: HealthResult = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private let aggregator: QueueAggregator
    private let configStore: ConfigStore
    private var foregroundTimer: Timer?
    private var backgroundTimer: Timer?
    private var intervalObservers: Set<AnyCancellable> = []
    private var optimisticOverrides: [String: OptimisticOverride] = [:]
    private var isRefreshing = false
    private var knownItemIDs: Set<String>?

    private struct OptimisticOverride {
        let kind: Kind
        let expiry: Date
        enum Kind {
            case status(QueueItem.Status)
            case deleted
        }
    }

    var activeCount: Int {
        (radarr + sonarr + lidarr).filter { $0.status != .completed }.count
    }

    init(configStore: ConfigStore = .shared) {
        self.configStore = configStore
        self.aggregator = QueueAggregator(configStore: configStore)
        startBackgroundPolling()

        configStore.$backgroundInterval
            .dropFirst()
            .sink { [weak self] _ in
                self?.restartBackgroundPolling()
            }
            .store(in: &intervalObservers)

        configStore.$foregroundInterval
            .dropFirst()
            .sink { [weak self] _ in
                self?.restartForegroundPolling()
            }
            .store(in: &intervalObservers)
    }

    func fetchHistory(for source: QueueItem.Source) async -> (items: [HistoryItem], error: String?) {
        do {
            let items: [HistoryItem]
            switch source {
            case .radarr: items = try await RadarrClient(config: configStore.radarr).fetchHistory()
            case .sonarr: items = try await SonarrClient(config: configStore.sonarr).fetchHistory()
            case .lidarr: items = try await LidarrClient(config: configStore.lidarr).fetchHistory()
            }
            return (items, nil)
        } catch {
            return ([], (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func startForegroundPolling() {
        Task { await self.refresh() }
        foregroundTimer?.invalidate()
        let interval = configStore.foregroundInterval
        guard interval > 0 else { return }
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func stopForegroundPolling() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    private func restartForegroundPolling() {
        guard foregroundTimer != nil else { return }
        startForegroundPolling()
    }

    private func startBackgroundPolling() {
        Task { await self.refresh() }
        backgroundTimer?.invalidate()
        let interval = configStore.backgroundInterval
        guard interval > 0 else { return }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    private func restartBackgroundPolling() {
        backgroundTimer?.invalidate()
        let interval = configStore.backgroundInterval
        guard interval > 0 else { return }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoading = true
        defer {
            isLoading = false
            isRefreshing = false
        }
        if DemoMode.isActive {
            self.radarr = DemoMocks.radarrQueue
            self.sonarr = DemoMocks.sonarrQueue
            self.lidarr = DemoMocks.lidarrQueue
            self.upcoming = DemoMocks.upcoming
            self.health = DemoMocks.health
            self.radarrError = nil
            self.sonarrError = nil
            self.lidarrError = nil
            self.lastError = nil
            return
        }
        async let queueResult = aggregator.fetch()
        async let upcomingResult = aggregator.fetchUpcoming()
        async let healthResult = aggregator.fetchHealth()
        let (queue, upcoming, health) = await (queueResult, upcomingResult, healthResult)
        let newRadarr = applyOverrides(to: queue.radarr)
        let newSonarr = applyOverrides(to: queue.sonarr)
        let newLidarr = applyOverrides(to: queue.lidarr)
        notifyNewItems(radarr: newRadarr, sonarr: newSonarr, lidarr: newLidarr)
        self.radarr = newRadarr
        self.sonarr = newSonarr
        self.lidarr = newLidarr
        self.radarrError = queue.radarrError
        self.sonarrError = queue.sonarrError
        self.lidarrError = queue.lidarrError
        self.upcoming = upcoming
        self.health = health
        self.lastError = nil
    }

    private func applyOverrides(to items: [QueueItem]) -> [QueueItem] {
        let now = Date()
        return items.compactMap { item in
            guard let override = optimisticOverrides[item.id] else { return item }
            if override.expiry < now {
                optimisticOverrides.removeValue(forKey: item.id)
                return item
            }
            switch override.kind {
            case .status(let status):
                if item.status == status {
                    optimisticOverrides.removeValue(forKey: item.id)
                    return item
                }
                return QueueItem(
                    id: item.id, source: item.source, arrQueueId: item.arrQueueId,
                    downloadId: item.downloadId, downloadProtocol: item.downloadProtocol,
                    downloadClient: item.downloadClient, title: item.title, subtitle: item.subtitle,
                    status: status, progress: item.progress, sizeTotal: item.sizeTotal,
                    sizeLeft: item.sizeLeft, timeLeft: item.timeLeft,
                    customFormats: item.customFormats, customFormatScore: item.customFormatScore,
                    quality: item.quality, isUpgrade: item.isUpgrade,
                    existingCustomFormats: item.existingCustomFormats,
                    existingCustomFormatScore: item.existingCustomFormatScore,
                    existingQuality: item.existingQuality,
                    contentSlug: item.contentSlug
                )
            case .deleted:
                return nil
            }
        }
    }

    // MARK: - Notifications

    private func notifyNewItems(radarr: [QueueItem], sonarr: [QueueItem], lidarr: [QueueItem]) {
        let allItems = radarr + sonarr + lidarr
        let currentIDs = Set(allItems.map(\.id))

        guard let known = knownItemIDs else {
            knownItemIDs = currentIDs
            return
        }

        let newItems = allItems.filter { !known.contains($0.id) }
        knownItemIDs = currentIDs

        for item in newItems {
            switch item.source {
            case .radarr where configStore.notifyRadarr: sendNotification(for: item)
            case .sonarr where configStore.notifySonarr: sendNotification(for: item)
            case .lidarr where configStore.notifyLidarr: sendNotification(for: item)
            default: break
            }
        }
    }

    private func sendNotification(for item: QueueItem) {
        let content = UNMutableNotificationContent()
        content.title = switch item.source {
        case .radarr: "Radarr"
        case .sonarr: "Sonarr"
        case .lidarr: "Lidarr"
        }
        content.subtitle = item.title
        var body = item.status.displayName
        if let quality = item.quality { body += " · \(quality)" }
        if item.isUpgrade { body += " · Upgrade" }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "arrbarr.\(item.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Actions

    func pause(_ item: QueueItem) async {
        await runAction(.pause, on: item)
    }
    func resume(_ item: QueueItem) async {
        await runAction(.resume, on: item)
    }
    func delete(_ item: QueueItem) async {
        await runAction(.delete, on: item)
    }

    private func runAction(_ action: QueueAggregator.Action, on item: QueueItem) async {
        do {
            try await aggregator.perform(action, on: item)
            lastError = nil
            applyOptimisticUpdate(action, on: item)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func applyOptimisticUpdate(_ action: QueueAggregator.Action, on item: QueueItem) {
        let overrideKind: OptimisticOverride.Kind = switch action {
        case .pause: .status(.paused)
        case .resume: .status(.downloading)
        case .delete: .deleted
        }

        optimisticOverrides[item.id] = OptimisticOverride(
            kind: overrideKind,
            expiry: Date().addingTimeInterval(30)
        )

        func update(_ items: inout [QueueItem]) {
            guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
            switch overrideKind {
            case .status(let newStatus):
                let old = items[idx]
                items[idx] = QueueItem(
                    id: old.id, source: old.source, arrQueueId: old.arrQueueId,
                    downloadId: old.downloadId, downloadProtocol: old.downloadProtocol,
                    downloadClient: old.downloadClient, title: old.title, subtitle: old.subtitle,
                    status: newStatus, progress: old.progress, sizeTotal: old.sizeTotal,
                    sizeLeft: old.sizeLeft, timeLeft: old.timeLeft,
                    customFormats: old.customFormats, customFormatScore: old.customFormatScore,
                    quality: old.quality, isUpgrade: old.isUpgrade,
                    existingCustomFormats: old.existingCustomFormats,
                    existingCustomFormatScore: old.existingCustomFormatScore,
                    existingQuality: old.existingQuality,
                    contentSlug: old.contentSlug
                )
            case .deleted:
                items.remove(at: idx)
            }
        }

        switch item.source {
        case .radarr: update(&radarr)
        case .sonarr: update(&sonarr)
        case .lidarr: update(&lidarr)
        }
    }
}
