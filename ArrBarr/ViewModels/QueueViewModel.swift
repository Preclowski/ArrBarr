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
    @Published private(set) var tonight: [UpcomingItem] = []
    @Published private(set) var needsYou: [NeedsYouItem] = []
    @Published private(set) var unreachableArrs: Set<QueueItem.Source> = []
    /// User clicked "+N more" on the Tonight banner. Reset every time the popover closes.
    @Published private(set) var tonightExpanded: Bool = false

    func setTonightExpanded(_ expanded: Bool) { tonightExpanded = expanded }
    @Published private(set) var health: HealthResult = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private let aggregator: QueueAggregator
    private let configStore: ConfigStore
    private let coalescer: NotificationCoalescer
    private var foregroundTimer: Timer?
    private var backgroundTimer: Timer?
    private var intervalObservers: Set<AnyCancellable> = []
    private var optimisticOverrides: [String: OptimisticOverride] = [:]
    @Published private(set) var isRefreshing = false
    private var knownItemIDs: Set<String>?

    /// Per-arr counter of consecutive refresh cycles where the queue fetch failed.
    /// We mark an arr as "unreachable" only after 3 in a row to ride out single-cycle
    /// blips (network hiccup, brief restart) without flapping the menu bar.
    private var consecutiveFailures: [QueueItem.Source: Int] = [:]
    private static let unreachableThreshold = 3

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

    /// Fires a sample banner so the user can preview the notification UI
    /// (score, tags, poster, actions) without waiting for a real grab.
    func fireTestNotification() {
        coalescer.postTest()
    }

    init(configStore: ConfigStore = .shared) {
        self.configStore = configStore
        self.aggregator = QueueAggregator(configStore: configStore)
        self.coalescer = NotificationCoalescer(configStore: configStore)
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

        configStore.$tonightHours
            .dropFirst()
            .sink { [weak self] hours in
                guard let self else { return }
                self.tonight = Self.tonightSlice(from: self.upcoming, hours: hours)
            }
            .store(in: &intervalObservers)
    }

    func fetchHistory(for source: QueueItem.Source) async -> HistoryResult {
        if DemoMode.isActive {
            return HistoryResult(items: DemoMocks.history(for: source), error: nil)
        }
        return await aggregator.fetchHistory(for: source)
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
        let hasExistingData = !radarr.isEmpty || !sonarr.isEmpty || !lidarr.isEmpty
        if !hasExistingData { isLoading = true }
        defer {
            if isLoading { isLoading = false }
            isRefreshing = false
        }
        if DemoMode.isActive {
            // Simulate a real network round-trip so the spinner is visible and
            // popover-blink regressions are easier to spot in demo mode.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.radarr = DemoMocks.radarrQueue
            self.sonarr = DemoMocks.sonarrQueue
            self.lidarr = []
            self.upcoming = DemoMocks.upcoming
            self.tonight = Self.tonightSlice(from: DemoMocks.upcoming, hours: configStore.tonightHours)
            self.health = DemoMocks.health
            self.radarrError = nil
            self.sonarrError = nil
            self.lidarrError = String(localized: "Network error: Could not connect to the server.")
            self.unreachableArrs = [.lidarr]
            self.needsYou = Self.computeNeedsYou(
                radarr: DemoMocks.radarrQueue,
                sonarr: DemoMocks.sonarrQueue,
                lidarr: [],
                health: DemoMocks.health
            )
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
        self.tonight = Self.tonightSlice(from: upcoming, hours: configStore.tonightHours)
        self.health = health
        self.unreachableArrs = updateUnreachable(
            radarrError: queue.radarrError,
            sonarrError: queue.sonarrError,
            lidarrError: queue.lidarrError
        )
        self.needsYou = Self.computeNeedsYou(
            radarr: newRadarr, sonarr: newSonarr, lidarr: newLidarr, health: health
        )
        self.lastError = nil
    }

    // MARK: - Derived state

    static func tonightSlice(from upcoming: [UpcomingItem], hours: Int) -> [UpcomingItem] {
        let now = Date()
        let cutoff = now.addingTimeInterval(TimeInterval(hours) * 3600)
        return upcoming.filter { $0.airDate >= now && $0.airDate <= cutoff }
    }

    static func computeNeedsYou(
        radarr: [QueueItem], sonarr: [QueueItem], lidarr: [QueueItem],
        health: HealthResult
    ) -> [NeedsYouItem] {
        (radarr + sonarr + lidarr)
            .filter { $0.status == .failed || $0.status == .warning }
            .map(NeedsYouItem.init)
    }

    /// Returns the set of arrs that have failed at least `unreachableThreshold` consecutive
    /// refresh cycles. A nil error string for an arr resets that arr's counter.
    private func updateUnreachable(
        radarrError: String?, sonarrError: String?, lidarrError: String?
    ) -> Set<QueueItem.Source> {
        let errors: [(QueueItem.Source, String?, Bool)] = [
            (.radarr, radarrError, configStore.radarr.isConfigured),
            (.sonarr, sonarrError, configStore.sonarr.isConfigured),
            (.lidarr, lidarrError, configStore.lidarr.isConfigured),
        ]
        var unreachable: Set<QueueItem.Source> = []
        for (source, error, configured) in errors {
            guard configured else {
                consecutiveFailures[source] = 0
                continue
            }
            if error != nil {
                consecutiveFailures[source, default: 0] += 1
                if (consecutiveFailures[source] ?? 0) >= Self.unreachableThreshold {
                    unreachable.insert(source)
                }
            } else {
                consecutiveFailures[source] = 0
            }
        }
        return unreachable
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
                var copy = item
                copy.status = status
                return copy
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
            let allowed: Bool = switch item.source {
            case .radarr: configStore.notifyRadarr
            case .sonarr: configStore.notifySonarr
            case .lidarr: configStore.notifyLidarr
            }
            if allowed { coalescer.enqueue(item) }
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
                items[idx].status = newStatus
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

struct NeedsYouItem: Identifiable, Equatable {
    let item: QueueItem

    init(_ item: QueueItem) { self.item = item }

    var id: String { "needsyou.\(item.id)" }
    var source: QueueItem.Source { item.source }
    var title: String { item.title }
    var subtitle: String {
        item.status == .warning
            ? String(localized: "Manual import required")
            : item.status.displayName
    }
}
