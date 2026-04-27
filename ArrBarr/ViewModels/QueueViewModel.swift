import Foundation
import Combine
import SwiftUI

@MainActor
final class QueueViewModel: ObservableObject {
    @Published private(set) var radarr: [QueueItem] = []
    @Published private(set) var sonarr: [QueueItem] = []
    @Published private(set) var radarrError: String?
    @Published private(set) var sonarrError: String?
    @Published private(set) var upcoming: [UpcomingItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private let aggregator: QueueAggregator
    private let configStore: ConfigStore
    private var foregroundTimer: Timer?
    private var backgroundTimer: Timer?
    private var intervalObservers: Set<AnyCancellable> = []
    private var optimisticOverrides: [String: OptimisticOverride] = [:]
    private var isRefreshing = false

    private struct OptimisticOverride {
        let kind: Kind
        let expiry: Date
        enum Kind {
            case status(QueueItem.Status)
            case deleted
        }
    }

    var activeCount: Int {
        (radarr + sonarr).filter { $0.status != .completed }.count
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
        async let queueResult = aggregator.fetch()
        async let upcomingResult = aggregator.fetchUpcoming()
        let (queue, upcoming) = await (queueResult, upcomingResult)
        self.radarr = applyOverrides(to: queue.radarr)
        self.sonarr = applyOverrides(to: queue.sonarr)
        self.radarrError = queue.radarrError
        self.sonarrError = queue.sonarrError
        self.upcoming = upcoming
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
                    contentSlug: item.contentSlug
                )
            case .deleted:
                return nil
            }
        }
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
                    contentSlug: old.contentSlug
                )
            case .deleted:
                items.remove(at: idx)
            }
        }

        switch item.source {
        case .radarr: update(&radarr)
        case .sonarr: update(&sonarr)
        }
    }
}
