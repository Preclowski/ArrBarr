import Foundation
import Combine
import SwiftUI
import UserNotifications

@MainActor
@Observable
public final class QueueViewModel {
    /// Per-source queue snapshot. Single source of truth; replaces the four
    /// `@Published var radarr/sonarr/lidarr/whisparr` properties we used to
    /// keep in sync by hand at every assignment site. Source.allCases lets
    /// loops iterate without naming each arr individually.
    public private(set) var queues: [QueueItem.Source: [QueueItem]] = [:]
    /// Per-source last-error string. Same shape as `queues`.
    public private(set) var errors: [QueueItem.Source: String] = [:]

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
    public private(set) var upcoming: [UpcomingItem] = []
    public private(set) var tonight: [UpcomingItem] = []
    public private(set) var needsYou: [NeedsYouItem] = []
    public private(set) var unreachableArrs: Set<QueueItem.Source> = []
    /// User clicked "+N more" on the Tonight banner. Reset every time the popover closes.
    public private(set) var tonightExpanded: Bool = false

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

    public private(set) var health: HealthResult = .empty
    public private(set) var isLoading = false
    /// Set once after the very first `refresh()` settles. The UI uses this to
    /// suppress the loading spinner on every subsequent poll — the previous
    /// rule (`!hasExistingData`) flashed the spinner whenever the queue
    /// happened to be empty, which on a healthy idle library was every
    /// background tick. Once true, we trust the existing rows to redraw with
    /// fresh values rather than tearing the surface down.
    public private(set) var hasLoadedOnce = false
    public private(set) var lastError: String?

    private let aggregator: QueueDataProviding
    private let configStore: ConfigStore
    private let coalescer: NotificationCoalescer
    private var foregroundTimer: Timer?
    private var backgroundTimer: Timer?
    private var intervalObservers: Set<AnyCancellable> = []
    private var optimisticOverrides: [String: OptimisticOverride] = [:]
    public private(set) var isRefreshing = false
    /// Set when `refresh()` is called while another refresh is mid-flight.
    /// The in-flight refresh's `defer` reads this and re-runs once so we
    /// never silently drop a trigger (the previous code's `guard !isRefreshing
    /// else { return }` was eating SignalR pushes that landed inside the
    /// ~half-second polling refreshes were taking).
    private var pendingRefresh = false
    /// Tracks which queue items have already been announced. Resilient to
    /// transient per-arr fetch failures, unstable queue record ids, and — via
    /// `loadNotificationTracker()` / `persistNotificationTracker()` —
    /// **app relaunches**. See `QueueNotificationTracker`.
    @ObservationIgnored
    private lazy var notificationTracker = Self.loadNotificationTracker(from: notificationDefaults)

    /// Where the notification cache is persisted. Defaults to `.standard`,
    /// matching `ConfigStore`'s sandbox-container store.
    private let notificationDefaults: UserDefaults
    private static let notificationTrackerKey = "ArrBarr.notificationTrackerState"

    private static func loadNotificationTracker(from defaults: UserDefaults) -> QueueNotificationTracker {
        guard let data = defaults.data(forKey: notificationTrackerKey),
              let tracker = try? JSONDecoder().decode(QueueNotificationTracker.self, from: data)
        else { return QueueNotificationTracker() }
        return tracker
    }

    private func persistNotificationTracker() {
        guard let data = try? JSONEncoder().encode(notificationTracker) else { return }
        notificationDefaults.set(data, forKey: Self.notificationTrackerKey)
    }

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

    /// Process-wide shared view-model. Used by both the AppDelegate (status
    /// bar badge updates) and the SwiftUI `MenuBarExtra` scene so they see
    /// the same queue snapshot and don't double-poll.
    public static let shared = QueueViewModel()

    public init(
        configStore: ConfigStore = .shared,
        notificationDefaults: UserDefaults = .standard
    ) {
        self.configStore = configStore
        self.notificationDefaults = notificationDefaults
        self.aggregator = QueueAggregator(configStore: configStore)
        self.coalescer = NotificationCoalescer(configStore: configStore)
        // Hold off setting `realtime`'s callback until `self` exists — we
        // capture weakly to avoid the manager retaining the view-model.
        let placeholder: @Sendable (RealtimeEvent) async -> Void = { _ in }
        self.realtime = RealtimeManager(onEvent: placeholder)
        commonSetup(autostart: true)
    }

    /// Test seam. Injects a fake `aggregator` and, with `autostart: false`,
    /// suppresses the polling timers + realtime bootstrap so `refresh()` can be
    /// driven deterministically without background fetches racing the test.
    /// Production goes through the public `init` above.
    init(
        configStore: ConfigStore,
        notificationDefaults: UserDefaults,
        aggregator: QueueDataProviding,
        autostart: Bool
    ) {
        self.configStore = configStore
        self.notificationDefaults = notificationDefaults
        self.aggregator = aggregator
        self.coalescer = NotificationCoalescer(configStore: configStore)
        let placeholder: @Sendable (RealtimeEvent) async -> Void = { _ in }
        self.realtime = RealtimeManager(onEvent: placeholder)
        commonSetup(autostart: autostart)
    }

    /// Wires polling, realtime bootstrap and config-change observers shared by
    /// both initializers. Split out so the public `init` stays *designated* —
    /// its `.shared` default argument keeps MainActor isolation, which a
    /// `convenience` delegation would lose.
    private func commonSetup(autostart: Bool) {
        // Coalesce bursts of queue events (Sonarr can emit several within
        // milliseconds during an import) so we don't fan out N near-
        // simultaneous HTTP refreshes.
        if autostart {
            startBackgroundPolling()

            Task { [weak self] in
                await self?.bootstrapRealtime()
            }
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

        // A successful "Test Connection" in Settings posts this — refresh now
        // so a freshly-saved key clears any stale per-arr error immediately.
        NotificationCenter.default.publisher(for: .arrBarrConfigValidated)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refresh() }
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
            self.needsYou = Self.computeNeedsYou(queues: self.queues, errors: [:], health: DemoMocks.health)
            self.lastError = nil
            return
        }
        async let queueResult = aggregator.fetch()
        async let upcomingResult = aggregator.fetchUpcoming()
        async let healthResult = aggregator.fetchHealth()
        let (queue, upcoming, health) = await (queueResult, upcomingResult, healthResult)
        // If this refresh's task was cancelled (e.g. pull-to-refresh released,
        // view torn down), the per-source fetches came back empty-with-no-error.
        // Committing that would blank the queue — bail and keep all current
        // state instead. The `defer` still resets the in-flight flags.
        if Task.isCancelled { return }
        let newErrors: [QueueItem.Source: String] = Dictionary(uniqueKeysWithValues:
            [
                (QueueItem.Source.radarr,   queue.radarrError),
                (.sonarr,                   queue.sonarrError),
                (.lidarr,                   queue.lidarrError),
                (.whisparr,                 queue.whisparrError),
            ].compactMap { source, msg in msg.map { (source, $0) } }
        )
        // Don't wipe a source's queue on a failed fetch: a flaky pull-to-
        // refresh (or any transient network error) returns an empty list +
        // an error string, which would otherwise blank the whole queue.
        // Keep the last good data for any errored source and let the error
        // surface separately (banner / unreachable state).
        func freshOrKept(_ source: QueueItem.Source, _ fresh: [QueueItem]) -> [QueueItem] {
            if newErrors[source] != nil { return self.queues[source] ?? [] }
            return applyOverrides(to: fresh)
        }
        let newQueues: [QueueItem.Source: [QueueItem]] = [
            .radarr:   freshOrKept(.radarr, queue.radarr),
            .sonarr:   freshOrKept(.sonarr, queue.sonarr),
            .lidarr:   freshOrKept(.lidarr, queue.lidarr),
            .whisparr: freshOrKept(.whisparr, queue.whisparr),
        ]
        notifyNewItems(queues: newQueues, errors: newErrors)
        self.queues = newQueues
        self.errors = newErrors
        // Same keep-last-good guard for upcoming: a failed refresh returns an
        // empty list, which would otherwise blank the Upcoming tab.
        if !(upcoming.isEmpty && !newErrors.isEmpty) {
            self.upcoming = upcoming
            self.tonight = Self.tonightSlice(from: upcoming, hours: configStore.tonightHours)
        }
        self.health = health
        self.unreachableArrs = updateUnreachable(errors: newErrors)
        self.needsYou = Self.computeNeedsYou(queues: newQueues, errors: newErrors, health: health)
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
        errors: [QueueItem.Source: String],
        health: HealthResult
    ) -> [NeedsYouItem] {
        // Iterate per Source.allCases (enum-declaration order) instead
        // of `queues.values` so the rendered "Needs you" list keeps a
        // stable Radarr → Sonarr → Lidarr → Whisparr order regardless
        // of dict hash order. Same content, deterministic surface.
        //
        // Written as an explicit loop rather than a `.lazy.flatMap.filter
        // .map(NeedsYouItem.init)` chain: that chain was the single most
        // expensive expression to type-check in the whole package
        // (~250 ms). The loop is equivalent and effectively free.
        let problemLabel = String(localized: "Service problem", bundle: .module)
        var result: [NeedsYouItem] = []
        for source in QueueItem.Source.allCases {
            // Queue items that need manual intervention.
            for item in queues[source] ?? [] where item.status == .failed || item.status == .warning {
                result.append(NeedsYouItem(item))
            }
            // Arr-level problems, grouped into ONE entry per source so an arr
            // with several issues shows them stacked under a single row (e.g.
            // "Sonarr" once, both problems beneath) instead of repeating the
            // app name. Includes:
            //  • a fetch error (ArrBarr couldn't reach the arr — explains a
            //    stale/empty queue; unconfigured arrs don't reach here since
            //    QueueAggregator swallows notConfigured/missingApiKey), and
            //  • error-level health checks the arr itself reports (e.g.
            //    "Download clients unavailable"). Benign notices/warnings stay
            //    on the header badge so this list isn't drowned in noise.
            var problems: [String] = []
            if let error = errors[source] { problems.append(error) }
            for record in health.records(for: source) where record.type?.lowercased() == "error" {
                if let message = record.message, !message.isEmpty { problems.append(message) }
            }
            if !problems.isEmpty {
                result.append(NeedsYouItem(
                    arrIssue: source,
                    id: "needsyou.issues.\(source.rawValue)",
                    title: source.displayName,
                    subtitle: problemLabel,
                    detailLines: problems
                ))
            }
        }
        return result
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

    /// Decides which newly-seen items warrant a banner. Errored arrs are passed
    /// through so a transient empty result never re-notifies a still-queued
    /// item — see `QueueNotificationTracker` for the full rationale.
    private func notifyNewItems(
        queues: [QueueItem.Source: [QueueItem]],
        errors: [QueueItem.Source: String]
    ) {
        let newItems = notificationTracker.newItems(
            perSource: queues,
            errored: Set(errors.keys)
        )
        // Persist the updated cache so relaunches don't re-announce items that
        // are still in the queue.
        persistNotificationTracker()
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
        // A queued/deferred item isn't paused — it's waiting behind the client's
        // queue limit. "Continue" force-starts it (adds to the active queue AND
        // begins downloading); a genuinely paused item just resumes.
        await runAction(item.status == .queued ? .continueDownload : .resume, on: item)
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
        guard StoreManager.shared.requirePro(.queueAction) else { return }
        do {
            try await aggregator.deleteAll(items)
            lastError = nil
            for item in items { applyOptimisticUpdate(.delete, on: item) }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func runAction(_ action: QueueAggregator.Action, on item: QueueItem) async {
        guard StoreManager.shared.requirePro(.queueAction) else { return }
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
        case .resume, .continueDownload: .status(.downloading)
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
    public let id: String
    public let source: QueueItem.Source
    public let title: String
    /// Short headline pill — for a queue item the status name (Failed /
    /// Manual import required); for an arr-level issue a generic label.
    public let subtitle: String
    /// The *why* rendered under the headline so the user can act without
    /// drilling in — the arr's status messages, or the error/health text.
    public let detailLines: [String]
    /// The underlying queue item when this row represents one; `nil` for
    /// arr-level issues (connection / health problems) that have no queue row.
    /// Consumers use it to drill into the item's detail — arr-issue rows fall
    /// back to opening the arr's queue page instead.
    public let item: QueueItem?

    public init(_ item: QueueItem) {
        self.item = item
        self.id = "needsyou.\(item.id)"
        self.source = item.source
        self.title = item.title
        self.subtitle = item.status == .warning
            ? String(localized: "Manual import required", bundle: .module)
            : item.status.displayName
        self.detailLines = item.statusMessages
    }

    /// An arr-level problem (couldn't reach the service, or the arr reports an
    /// error-level health check) rather than a single stuck download.
    public init(
        arrIssue source: QueueItem.Source,
        id: String,
        title: String,
        subtitle: String,
        detailLines: [String]
    ) {
        self.item = nil
        self.id = id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.detailLines = detailLines
    }
}
