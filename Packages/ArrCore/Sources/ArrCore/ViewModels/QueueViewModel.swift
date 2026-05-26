import Foundation
import Combine
import SwiftUI
import UserNotifications

@MainActor
public final class QueueViewModel: ObservableObject {
    /// Per-source queue snapshot. Single source of truth; replaces the four
    /// `@Published var radarr/sonarr/lidarr/whisparr` properties we used to
    /// keep in sync by hand at every assignment site. Source.allCases lets
    /// loops iterate without naming each arr individually.
    @Published public private(set) var queues: [QueueItem.Source: [QueueItem]] = [:]
    /// Per-source last-error string. Same shape as `queues`.
    @Published public private(set) var errors: [QueueItem.Source: String] = [:]

    // Back-compat named accessors. Existing consumers (DetailView, status-bar
    // badge, history lookup) read these. Keep them as computed so the dict
    // stays the only source of truth.
    public var radarr: [QueueItem]   { queues[.radarr,   default: []] }
    public var sonarr: [QueueItem]   { queues[.sonarr,   default: []] }
    public var lidarr: [QueueItem]   { queues[.lidarr,   default: []] }
    public var whisparr: [QueueItem] { queues[.whisparr, default: []] }
    public var radarrError: String?   { errors[.radarr] }
    public var sonarrError: String?   { errors[.sonarr] }
    public var lidarrError: String?   { errors[.lidarr] }
    public var whisparrError: String? { errors[.whisparr] }
    @Published public private(set) var upcoming: [UpcomingItem] = []
    @Published public private(set) var tonight: [UpcomingItem] = []
    @Published public private(set) var needsYou: [NeedsYouItem] = []
    @Published public private(set) var unreachableArrs: Set<QueueItem.Source> = []
    /// User clicked "+N more" on the Tonight banner. Reset every time the popover closes.
    @Published public private(set) var tonightExpanded: Bool = false

    public func setTonightExpanded(_ expanded: Bool) { tonightExpanded = expanded }

    /// Source-keyed accessors for the per-arr queue / error pair. Replaces
    /// the four-way switches that PopoverContentView, DetailView and others
    /// used to redeclare locally.
    public func items(for source: QueueItem.Source) -> [QueueItem] {
        queues[source, default: []]
    }

    public func error(for source: QueueItem.Source) -> String? {
        errors[source]
    }

    /// True when no arr has any queued items. Used by both surfaces to show
    /// the "Nothing in queue" empty state instead of dispatching to per-arr
    /// sections that would each render their own empty placeholders.
    public var allEmpty: Bool {
        queues.values.allSatisfy { $0.isEmpty }
    }

    @Published public private(set) var health: HealthResult = .empty
    @Published public private(set) var isLoading = false
    /// Set once after the very first `refresh()` settles. The UI uses this to
    /// suppress the loading spinner on every subsequent poll — the previous
    /// rule (`!hasExistingData`) flashed the spinner whenever the queue
    /// happened to be empty, which on a healthy idle library was every
    /// background tick. Once true, we trust the existing rows to redraw with
    /// fresh values rather than tearing the surface down.
    @Published public private(set) var hasLoadedOnce = false
    @Published public private(set) var lastError: String?

    private let aggregator: QueueAggregator
    private let configStore: ConfigStore
    private let coalescer: NotificationCoalescer
    private var foregroundTimer: Timer?
    private var backgroundTimer: Timer?
    private var intervalObservers: Set<AnyCancellable> = []
    private var optimisticOverrides: [String: OptimisticOverride] = [:]
    @Published public private(set) var isRefreshing = false
    /// Set when `refresh()` is called while another refresh is mid-flight.
    /// The in-flight refresh's `defer` reads this and re-runs once so we
    /// never silently drop a trigger (the previous code's `guard !isRefreshing
    /// else { return }` was eating SignalR pushes that landed inside the
    /// ~half-second polling refreshes were taking).
    private var pendingRefresh = false
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

    public var activeCount: Int {
        queues.values.lazy.flatMap { $0 }.filter { $0.status != .completed }.count
    }

    /// Fires a sample banner so the user can preview the notification UI
    /// (score, tags, poster, actions) without waiting for a real grab.
    public func fireTestNotification() {
        coalescer.postTest()
    }

    /// Pushes real-time updates from each arr's SignalR hub straight
    /// into a debounced refresh. Polling stays as fallback.
    private let realtime: RealtimeManager

    public init(configStore: ConfigStore = .shared) {
        self.configStore = configStore
        self.aggregator = QueueAggregator(configStore: configStore)
        self.coalescer = NotificationCoalescer(configStore: configStore)

        // Hold off setting `realtime`'s callback until `self` exists —
        // we capture weakly to avoid the manager retaining the
        // view-model. Coalesce bursts of queue events (Sonarr can
        // emit several within milliseconds during an import) so we
        // don't fan out N near-simultaneous HTTP refreshes.
        let placeholder: @Sendable (RealtimeEvent) async -> Void = { _ in }
        self.realtime = RealtimeManager(onEvent: placeholder)

        startBackgroundPolling()

        Task { [weak self] in
            await self?.bootstrapRealtime()
        }

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

        // Re-subscribe when any arr's connection details change. The
        // manager diffs internally so unchanged arrs keep their open
        // sockets.
        Publishers.CombineLatest4(
            configStore.$sonarr, configStore.$radarr,
            configStore.$lidarr, configStore.$whisparr
        )
        .dropFirst()
        .sink { [weak self] sonarr, radarr, lidarr, whisparr in
            Task { [weak self] in
                await self?.realtime.reconfigure(
                    sonarr: sonarr, radarr: radarr,
                    lidarr: lidarr, whisparr: whisparr
                )
            }
        }
        .store(in: &intervalObservers)
    }

    deinit {
        Task { [realtime] in await realtime.shutdown() }
    }

    /// Hook up the realtime callback and subscribe to the initial
    /// configuration. Runs once at init time, after `self` is fully
    /// constructed so the weak-self capture is valid.
    private func bootstrapRealtime() async {
        // Replace the placeholder callback with one that refreshes
        // the queue for the affected arr. Debounce so a flurry of
        // queue events (common during episode import) collapses into
        // a single HTTP roundtrip.
        await realtime.setHandler { [weak self] event in
            guard let self else { return }
            switch event {
            case .queueChanged, .fileImported:
                await self.scheduleRealtimeRefresh()
            case .other:
                break
            }
        }
        await realtime.reconfigure(
            sonarr: configStore.sonarr,
            radarr: configStore.radarr,
            lidarr: configStore.lidarr,
            whisparr: configStore.whisparr
        )
    }

    /// Coalesce realtime triggers: collapse a burst of arr events into
    /// one refresh roughly 250 ms after the last one, so Sonarr's
    /// "queue add, progress, file import" sequence becomes a single
    /// fetch.
    @MainActor
    private func scheduleRealtimeRefresh() {
        realtimeDebounce?.invalidate()
        realtimeDebounce = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }
    @MainActor private var realtimeDebounce: Timer?

    func fetchHistory(for source: QueueItem.Source) async -> HistoryResult {
        if DemoMode.isActive {
            return HistoryResult(items: DemoMocks.history(for: source), error: nil)
        }
        return await aggregator.fetchHistory(for: source)
    }

    public func startForegroundPolling() {
        Task { await self.refresh() }
        foregroundTimer?.invalidate()
        let interval = configStore.foregroundInterval
        guard interval > 0 else { return }
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    public func stopForegroundPolling() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    /// Called from AppDelegate's `NSWorkspace.didWakeNotification`
    /// observer. macOS can let WebSockets sit half-dead for tens of
    /// seconds after a wake; the reconnect loop only fires once the
    /// OS surfaces the failed `receive`, so the user experiences a
    /// dead-period of stale data. Force a tear-and-rebuild of every
    /// SignalR connection + an immediate poll, so the moment the
    /// user opens the popover post-wake everything is current.
    public func systemDidWake() {
        Task {
            await self.realtime.forceReconnect()
            await self.refresh()
        }
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

    public func refresh() async {
        // Queue-not-drop: if a refresh is already in flight, set
        // `pendingRefresh` and bail out. After the in-flight one finishes
        // the `defer` re-checks and runs once more — collapses bursts
        // into "at most two back-to-back fetches" instead of dropping
        // the second trigger entirely. The dropped-event case was
        // observable: a SignalR push arriving 50 ms after a polling
        // refresh started would `return` here and the SignalR update
        // never reached the user.
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        if !hasLoadedOnce { isLoading = true }
        defer {
            isLoading = false
            hasLoadedOnce = true
            isRefreshing = false
            // Drain any trigger we received while we were busy.
            if pendingRefresh {
                pendingRefresh = false
                Task { await self.refresh() }
            }
        }
        if DemoMode.isActive {
            // Simulate a real network round-trip so the spinner is visible and
            // popover-blink regressions are easier to spot in demo mode.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.queues = [
                .radarr:   DemoMocks.radarrQueue,
                .sonarr:   DemoMocks.sonarrQueue,
                .lidarr:   DemoMocks.lidarrQueue,
                .whisparr: DemoMocks.whisparrQueue,
            ]
            self.upcoming = DemoMocks.upcoming
            self.tonight = Self.tonightSlice(from: DemoMocks.upcoming, hours: configStore.tonightHours)
            self.health = DemoMocks.health
            self.errors = [:]
            self.unreachableArrs = []
            self.needsYou = Self.computeNeedsYou(queues: self.queues, health: DemoMocks.health)
            self.lastError = nil
            return
        }
        async let queueResult = aggregator.fetch()
        async let upcomingResult = aggregator.fetchUpcoming()
        async let healthResult = aggregator.fetchHealth()
        let (queue, upcoming, health) = await (queueResult, upcomingResult, healthResult)
        let newQueues: [QueueItem.Source: [QueueItem]] = [
            .radarr:   applyOverrides(to: queue.radarr),
            .sonarr:   applyOverrides(to: queue.sonarr),
            .lidarr:   applyOverrides(to: queue.lidarr),
            .whisparr: applyOverrides(to: queue.whisparr),
        ]
        let newErrors: [QueueItem.Source: String] = Dictionary(uniqueKeysWithValues:
            [
                (QueueItem.Source.radarr,   queue.radarrError),
                (.sonarr,                   queue.sonarrError),
                (.lidarr,                   queue.lidarrError),
                (.whisparr,                 queue.whisparrError),
            ].compactMap { source, msg in msg.map { (source, $0) } }
        )
        notifyNewItems(queues: newQueues)
        self.queues = newQueues
        self.errors = newErrors
        self.upcoming = upcoming
        self.tonight = Self.tonightSlice(from: upcoming, hours: configStore.tonightHours)
        self.health = health
        self.unreachableArrs = updateUnreachable(errors: newErrors)
        self.needsYou = Self.computeNeedsYou(queues: newQueues, health: health)
        self.lastError = nil
    }

    // MARK: - Derived state

    static func tonightSlice(from upcoming: [UpcomingItem], hours: Int) -> [UpcomingItem] {
        let now = Date()
        let cutoff = now.addingTimeInterval(TimeInterval(hours) * 3600)
        return upcoming.filter { $0.airDate >= now && $0.airDate <= cutoff }
    }

    static func computeNeedsYou(
        queues: [QueueItem.Source: [QueueItem]],
        health: HealthResult
    ) -> [NeedsYouItem] {
        // Iterate per Source.allCases (enum-declaration order) instead
        // of `queues.values` so the rendered "Needs you" list keeps a
        // stable Radarr → Sonarr → Lidarr → Whisparr order regardless
        // of dict hash order. Same content, deterministic surface.
        QueueItem.Source.allCases
            .lazy
            .flatMap { queues[$0] ?? [] }
            .filter { $0.status == .failed || $0.status == .warning }
            .map(NeedsYouItem.init)
    }

    /// Returns the set of arrs that have failed at least `unreachableThreshold` consecutive
    /// refresh cycles. A nil error string for an arr resets that arr's counter.
    private func updateUnreachable(errors: [QueueItem.Source: String]) -> Set<QueueItem.Source> {
        var unreachable: Set<QueueItem.Source> = []
        for source in QueueItem.Source.allCases {
            guard configStore.config(for: source.serviceKind).isConfigured else {
                consecutiveFailures[source] = 0
                continue
            }
            if errors[source] != nil {
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

    private func notifyNewItems(queues: [QueueItem.Source: [QueueItem]]) {
        let allItems = Array(queues.values.joined())
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
            case .whisparr: false  // no notify toggle for Whisparr
            }
            if allowed { coalescer.enqueue(item) }
        }
    }

    // MARK: - Actions

    public func pause(_ item: QueueItem) async {
        await runAction(.pause, on: item)
    }
    public func resume(_ item: QueueItem) async {
        await runAction(.resume, on: item)
    }
    public func delete(_ item: QueueItem) async {
        await runAction(.delete, on: item)
    }

    /// Bulk delete used for season packs and virtual season bundles. For a
    /// real pack (one shared `downloadId`) the underlying download is
    /// removed by the first call only and the rest just clean up sibling
    /// queue rows. For a virtual bundle (N independent `downloadId`s) every
    /// call must remove from the client because each member is its own
    /// physical download. `aggregator.deleteAll` infers which case applies
    /// from the items' downloadIds.
    public func deleteAll(_ items: [QueueItem]) async {
        guard !items.isEmpty else { return }
        do {
            try await aggregator.deleteAll(items)
            lastError = nil
            for item in items { applyOptimisticUpdate(.delete, on: item) }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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

        var bucket = queues[item.source, default: []]
        if let idx = bucket.firstIndex(where: { $0.id == item.id }) {
            switch overrideKind {
            case .status(let newStatus):
                bucket[idx].status = newStatus
            case .deleted:
                bucket.remove(at: idx)
            }
            queues[item.source] = bucket
        }
    }
}

public struct NeedsYouItem: Identifiable, Equatable {
    public let item: QueueItem

    public init(_ item: QueueItem) { self.item = item }

    public var id: String { "needsyou.\(item.id)" }
    public var source: QueueItem.Source { item.source }
    public var title: String { item.title }
    public var subtitle: String {
        item.status == .warning
            ? String(localized: "Manual import required", bundle: .module)
            : item.status.displayName
    }
}
