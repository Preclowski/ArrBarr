import Foundation
import MediaKit
import Combine
import SwiftUI
import UserNotifications
import os

@Observable
public final class QueueViewModel {
    public private(set) var queues: [QueueItem.Source: [QueueItem]] = [:]
    public private(set) var errors: [QueueItem.Source: String] = [:]

    public private(set) var upcoming: [UpcomingItem] = []
    public private(set) var tonight: [UpcomingItem] = []
    public private(set) var needsYou: [NeedsYouItem] = []
    public private(set) var unreachableArrs: Set<QueueItem.Source> = []
    /// Sources whose fetch failed at the transport level this cycle. Not debounced like `unreachableArrs`,
    /// so a section shows the calm "can't reach" state at once instead of an error for three cycles.
    public private(set) var lastUnreachable: Set<QueueItem.Source> = []
    /// Last refresh in which any configured arr returned fresh data; `nil` until the first success.
    public private(set) var lastSuccessfulRefresh: Date?
    /// Reset every time the popover closes.
    public private(set) var tonightExpanded: Bool = false

    public func setTonightExpanded(_ expanded: Bool) { tonightExpanded = expanded }

    public func items(for source: QueueItem.Source) -> [QueueItem] {
        queues[source, default: []]
    }

    public func error(for source: QueueItem.Source) -> String? {
        errors[source]
    }

    /// Popover open or detached window visible. Calendar, health dots and probes render only in the panel,
    /// so they are not fetched while it is hidden.
    private var isPanelVisible = false

    private var configuredArrs: Set<QueueItem.Source> {
        Set(QueueItem.Source.allCases.filter {
            configStore.config(for: $0.serviceKind).isConfigured
        })
    }

    /// Every configured arr is unreachable — the user has left the home LAN. False when nothing is configured.
    public var isFullyOffline: Bool {
        let configured = configuredArrs
        return !configured.isEmpty && configured.isSubset(of: unreachableArrs)
    }

    public private(set) var health: HealthResult = .empty
    public private(set) var isLoading = false
    /// Set after the first `refresh()` settles; later polls never show the loading spinner, even on an empty queue.
    public private(set) var hasLoadedOnce = false {
        didSet { if hasLoadedOnce, !oldValue { Self.logFirstLoad() } }
    }
    public private(set) var lastError: String?

    private let aggregator: QueueDataProviding
    private let configStore: ConfigStore
    private let coalescer: NotificationCoalescer
    private let connectionMonitor = ConnectionHealthMonitor()
    private var queueUpdatesTask: Task<Void, Never>?
    private var committedRevision: [QueueItem.Source: QueueRevision] = [:]
    private var liveQueuesStarted = false
    /// The streams start after it so their first tick finds a fresh reading instead of a second fetch.
    private var initialRefresh: Task<Void, Never>?
    private var intervalObservers: Set<AnyCancellable> = []
    private var configValidatedTask: Task<Void, Never>?
    private var artworkChangedTask: Task<Void, Never>?
    public private(set) var isRefreshing = false
    /// A refresh requested mid-flight re-runs once from the in-flight `defer`, so a SignalR push is never dropped.
    private var pendingRefresh = false
    @ObservationIgnored
    private lazy var notificationTracker = Self.loadNotificationTracker(from: notificationDefaults)

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

    @ObservationIgnored
    private lazy var healthTracker: HealthNotificationTracker = {
        guard let data = notificationDefaults.data(forKey: Self.healthTrackerKey),
              let tracker = try? JSONDecoder().decode(HealthNotificationTracker.self, from: data)
        else { return HealthNotificationTracker() }
        return tracker
    }()
    private static let healthTrackerKey = "ArrBarr.healthNotificationTrackerState"

    private func persistHealthTracker() {
        guard let data = try? JSONEncoder().encode(healthTracker) else { return }
        notificationDefaults.set(data, forKey: Self.healthTrackerKey)
    }

    /// Consecutive failed queue fetches; an arr is marked unreachable only after 3, to ride out blips.
    private var consecutiveFailures: [QueueItem.Source: Int] = [:]
    private static let unreachableThreshold = 3


    public var activeCount: Int {
        queues.values.lazy.flatMap { $0 }.filter { $0.status != .completed }.count
    }

    public func fireTestNotification() {
        coalescer.postTest()
    }

    @ObservationIgnored private var realtimeTask: Task<Void, Never>?
    @ObservationIgnored private var breakerTask: Task<Void, Never>?
    @ObservationIgnored private var invalidationObserver: NotificationCenter.ObservationToken?

    /// Shared by the AppDelegate and the `MenuBarExtra` scene so they see one snapshot and don't double-poll.
    public static let shared = QueueViewModel(configStore: .shared)

    public init(
        configStore: ConfigStore,
        notificationDefaults: UserDefaults = .standard
    ) {
        self.configStore = configStore
        self.notificationDefaults = notificationDefaults
        self.aggregator = QueueAggregator(configStore: configStore)
        self.coalescer = NotificationCoalescer(configStore: configStore)
        commonSetup(autostart: true)
    }

    /// Test seam: `autostart: false` suppresses timers and realtime so `refresh()` runs deterministically.
    // periphery:ignore
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
        commonSetup(autostart: autostart)
    }

    /// Split out so the public `init` stays designated: its `.shared` default argument keeps MainActor
    /// isolation, which a `convenience` delegation would lose.
    private func commonSetup(autostart: Bool) {
        // Cold-start with the last-known calendar snapshot so it shows even away from the LAN.
        if autostart, !DemoMode.isActive {
            Task { [weak self] in
                let cached = await WidgetDataStore.loadUpcomingAsync()
                guard let self, !cached.isEmpty else { return }
                // A live refresh may have finished during the read; it is fresher, so the cache defers to it.
                guard self.upcoming.isEmpty else { return }
                self.upcoming = cached
                self.tonight = Self.tonightSlice(from: cached, hours: self.configStore.tonightHours)
            }
        }
        // Coalesce bursts (Sonarr emits several queue events within milliseconds during an import).
        if autostart {
            startBackgroundPolling()
            startAuxiliaryPolling()

            // Run off `init`: touching `configStore.gateway` inside a `static let` initializer launches the app
            // with no configured instances.
            Task { [weak self] in
                await self?.bootstrapRealtime()
                self?.bootstrapCalendarInvalidation()
                self?.bootstrapBreakers()
            }
        }

        configStore.$tonightHours
            .dropFirst()
            .sink { [weak self] hours in
                guard let self else { return }
                self.tonight = Self.tonightSlice(from: self.upcoming, hours: hours)
            }
            .store(in: &intervalObservers)

        // An arr added or removed starts or stops its queue stream. Probes are debounced because Settings
        // writes to `ConfigStore` per keystroke.
        for source in QueueItem.Source.allCases {
            configStore.publisher(for: source.serviceKind)
                .dropFirst()
                .map(\.isConfigured)
                .removeDuplicates()
                .sink { [weak self] _ in Task { await self?.updateLiveQueues() } }
                .store(in: &intervalObservers)
        }
        for kind in MonitoredService.downloadClientKinds {
            configStore.publisher(for: kind)
                .dropFirst()
                .removeDuplicates()
                .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.reprobe(.arr(kind)) }
                .store(in: &intervalObservers)
        }
        configStore.$openai
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reprobe(.openai) }
            .store(in: &intervalObservers)
        configStore.$tmdbApiKey
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reprobe(.tmdb) }
            .store(in: &intervalObservers)
        configStore.$mediaServer
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reprobe(.mediaServer) }
            .store(in: &intervalObservers)
        configStore.$prowlarr
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reprobe(.prowlarr) }
            .store(in: &intervalObservers)

        configValidatedTask = Task { [weak self] in
            for await _ in NotificationCenter.default.messages(of: nil as AppMessageBus?, for: AppMessages.ConfigValidated.self) {
                await self?.refresh()
            }
        }
        artworkChangedTask = Task { [weak self] in
            for await _ in NotificationCenter.default.messages(of: nil as AppMessageBus?, for: AppMessages.MediaServerArtworkChanged.self) {
                await self?.refreshQueues()
            }
        }
    }

    /// `isolated` because a nonisolated `deinit` cannot touch the timers, and `invalidate()` must run on
    /// the run loop that installed them (`RunLoop.main`).
    isolated deinit {
        realtimeTask?.cancel()
        breakerTask?.cancel()
        upcomingRefreshTask?.cancel()
        configValidatedTask?.cancel()
        artworkChangedTask?.cancel()
        // A scheduled `Timer` is owned by the run loop, so dropping the view-model does not stop it.
        queueUpdatesTask?.cancel()
        healthDebounce?.invalidate()
        upcomingTimer?.invalidate()
        healthTimer?.invalidate()
    }

    private func bootstrapRealtime() async {
        let events = await configStore.gateway.events.events()
        realtimeTask?.cancel()
        realtimeTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                // Queue pushes reach the queue streams through the hub; only health is refreshed from here.
                guard case let .healthChanged(instance) = event, QueueItem.Source(rawValue: instance.kind.rawValue) != nil else { continue }
                self.scheduleHealthRefresh()
            }
        }
        let gateway = configStore.gateway
        let updates = gateway.queueUpdates()
        queueUpdatesTask?.cancel()
        queueUpdatesTask = Task { [weak self] in
            for await source in updates {
                guard let self, !Task.isCancelled else { return }
                await self.commitLatestQueue(source: source)
            }
        }
        await initialRefresh?.value
        liveQueuesStarted = true
        await updateLiveQueues()
    }

    private func updateLiveQueues() async {
        guard liveQueuesStarted else { return }
        var policy = LivePolicy.queue
        policy.foregroundInterval = .seconds(configStore.foregroundInterval)
        policy.backgroundInterval = .seconds(configStore.backgroundInterval)
        policy.pushSilence = .seconds(configStore.realtimeSilenceTimeout)
        await configStore.gateway.setLiveQueues(sources: QueueItem.Source.allCases.filter { configuredArrs.contains($0) },
                                                activity: isPanelVisible ? .foreground : .background, policy: policy)
    }

    private func commitLatestQueue(source: QueueItem.Source) async {
        guard configuredArrs.contains(source) else { return }
        // Composing costs side-load reads; an already committed revision needs none.
        if let revision = aggregator.latestRevision(source: source), revision.isCovered(by: committedRevision[source]) { return }
        let result = await aggregator.latest(source: source)
        if Task.isCancelled { return }
        commitQueue(result)
        hasLoadedOnce = true
    }

    private func bootstrapBreakers() {
        let changes = configStore.gateway.breakerChanges()
        breakerTask?.cancel()
        breakerTask = Task { [weak self] in
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                self.applyBreakers()
            }
        }
    }

    private func applyBreakers() {
        let gateway = configStore.gateway
        ConnectionHealth.shared.noteBreakers(Set(MonitoredService.allCases.filter {
            if case .down = gateway.hostHealth(of: $0) { $0.isConfigured(in: configStore) } else { false }
        }))
    }

    /// Watches the store's invalidation, not the raw event: `EventHub` invalidates a burst window after
    /// delivering the event, so an event-driven re-read would commit the pre-import state.
    func bootstrapCalendarInvalidation() {
        let calendarTags = Set(QueueItem.Source.allCases.map { InvalidationTag.collection(.calendar, $0.instanceID) })
        // `addObserver` registers before it returns, unlike an `AsyncSequence`, so nothing slips through.
        invalidationObserver = NotificationCenter.default.addObserver(
            of: configStore.gateway.kit.subject, for: Invalidated.self
        ) { [weak self] message in
            guard !message.tags.isDisjoint(with: calendarTags) else { return }
            await self?.scheduleUpcomingRefresh()
        }
    }

    /// One re-read at a time: an invalidation arriving mid-read sets the flag instead of being dropped.
    @MainActor
    func scheduleUpcomingRefresh() {
        guard upcomingRefreshTask == nil else {
            upcomingRefreshAgain = true
            return
        }
        upcomingRefreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                upcomingRefreshAgain = false
                await refreshUpcoming()
            } while upcomingRefreshAgain
            upcomingRefreshTask = nil
        }
    }
    @ObservationIgnored @MainActor private var upcomingRefreshTask: Task<Void, Never>?
    @ObservationIgnored @MainActor private var upcomingRefreshAgain = false

    /// Not throttled beyond burst collapsing: Servarr raises `HealthCheckCompleteEvent` only when it runs
    /// its own check, not per download.
    @MainActor
    private func scheduleHealthRefresh() {
        healthDebounce?.invalidate()
        healthDebounce = Self.commonModeTimer(interval: 2, repeats: false) { [weak self] in
            Task { await self?.refreshHealth() }
        }
    }
    @MainActor private var healthDebounce: Timer?

    private static let upcomingInterval: TimeInterval = 30 * 60
    /// Backstop for when Servarr's health push never arrives (older Servarr, a proxy dropping the frame).
    private static let healthInterval: TimeInterval = 15 * 60
    @MainActor private var upcomingTimer: Timer?
    @MainActor private var healthTimer: Timer?

    @MainActor
    private func startAuxiliaryPolling() {
        // The calendar renders only in the panel, and opening the panel runs a full `refresh()`.
        upcomingTimer?.invalidate()
        upcomingTimer = Self.commonModeTimer(interval: Self.upcomingInterval, repeats: true) { [weak self] in
            Task { [weak self] in
                guard let self, self.isPanelVisible else { return }
                await self.refreshUpcoming()
            }
        }
        // Health keeps running while hidden: an indexer outage is most useful to learn when not looking,
        // and the fetch is small.
        healthTimer?.invalidate()
        healthTimer = Self.commonModeTimer(interval: Self.healthInterval, repeats: true) { [weak self] in
            Task { await self?.refreshHealth() }
        }
    }

    @MainActor private(set) var measuredAt: [QueueItem.Source: Date] = [:]

    /// Progress interpolation runs from this; `.distantPast` means no interpolation.
    @MainActor
    public func progressMeasuredAt(for source: QueueItem.Source) -> Date {
        measuredAt[source] ?? .distantPast
    }

    /// `.common` mode keeps firing while the menu-bar panel tracks events; `Timer.scheduledTimer`'s
    /// `.default` mode pauses during scroll.
    private static func commonModeTimer(
        interval: TimeInterval, repeats: Bool, _ fire: @escaping () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in fire() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// One raw page; pairing and folding run over all loaded pages in `HistoryFeed`.
    func fetchHistory(for source: QueueItem.Source, page: Int, entityId: Int? = nil) async -> HistoryResult {
        let pageSize = HistoryFeed.pageSize
        return await aggregator.fetchHistory(for: source, page: page, pageSize: pageSize, entityId: entityId)
    }

    /// Kept for the app's lifetime: the popover rebuilds its History view on every open.
    @ObservationIgnored private var historyFeeds: [HistoryFeedKey: HistoryFeed] = [:]

    private struct HistoryFeedKey: Hashable {
        let sources: [QueueItem.Source]
        let entityId: Int?
    }

    /// `entityId` scopes the feed to one library record; nil is the arr-wide feed.
    func historyFeed(for sources: [QueueItem.Source], entityId: Int? = nil) -> HistoryFeed {
        let key = HistoryFeedKey(sources: sources, entityId: entityId)
        if let cached = historyFeeds[key] { return cached }
        let feed = HistoryFeed(sources: sources) { [weak self] source, page in
            await self?.fetchHistory(for: source, page: page, entityId: entityId) ?? HistoryResult(items: [], error: nil)
        }
        historyFeeds[key] = feed
        return feed
    }

    public func startForegroundPolling() {
        isPanelVisible = true
        // Refresh first: flipping the streams to foreground wakes their pumps, which then find a fresh reading.
        Task {
            await self.refresh()
            await self.updateLiveQueues()
        }
    }

    public func stopForegroundPolling() {
        isPanelVisible = false
        Task { await self.updateLiveQueues() }
    }

    /// macOS can leave WebSockets half-dead for tens of seconds after a wake, so rebuild every SignalR
    /// connection and poll immediately.
    public func systemDidWake() {
        Task {
            await configStore.gateway.systemDidWake()
            await self.refresh()
        }
    }


    private func startBackgroundPolling() {
        initialRefresh = Task { await self.refresh() }
    }

    /// Gated on Control here too: a lapsed entitlement leaves a configured server behind.
    private func refreshMediaServerIndex() {
        let config = configStore.mediaServer
        guard StoreManager.shared.isPro else {
            MediaServerIndex.shared.clear()
            return
        }
        Task.detached(priority: .utility) {
            await MediaServerIndex.shared.refreshIfStale(config: config)
        }
    }

    private static let launchLog = Logger(category: "Launch")
    private static var loggedFirstLoad = false

    private static func logFirstLoad() {
        guard !loggedFirstLoad else { return }
        loggedFirstLoad = true
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let ms = Int((Date().timeIntervalSince1970 - started) * 1000)
        launchLog.notice("first queue load \(ms, privacy: .public) ms after process start")
    }

    public func refresh() async {
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        // `refreshIfStale` is cheap in the common case and runs detached, so a slow server never delays the queue.
        refreshMediaServerIndex()
        if !hasLoadedOnce { isLoading = true }
        defer {
            isLoading = false
            hasLoadedOnce = true
            isRefreshing = false
            if pendingRefresh {
                pendingRefresh = false
                Task { await self.refresh() }
            }
        }
        // The repeating foreground tick calls `refreshQueues()` instead, so calendars and health are not
        // re-pulled every 5 seconds.
        async let queueResult = aggregator.fetch()
        async let upcomingResult = aggregator.fetchUpcoming()
        async let healthResult = aggregator.fetchHealth()
        let (queue, upcoming, freshHealth) = await (queueResult, upcomingResult, healthResult)
        // A cancelled task's fetches come back empty-with-no-error; committing them would blank the queue.
        if Task.isCancelled { return }
        // Health first: `commitQueue` recomputes "Needs you", which merges it.
        health = freshHealth
        // Configured only: an unconfigured arr's empty-with-no-error slice would read as a successful fetch.
        for source in QueueItem.Source.allCases where configuredArrs.contains(source) {
            commitQueue(queue.slice(for: source))
        }
        commitUpcoming(items: upcoming.items, failed: upcoming.failed)
    }

    /// Per-source keep-last-good: a failed source keeps its previous entries, a reachable one replaces its slice.
    private func commitUpcoming(items: [UpcomingItem], failed: Set<QueueItem.Source>) {
        let freshBySource = Dictionary(grouping: items, by: { $0.source })
        let startOfToday = Calendar.current.startOfDay(for: Date())
        var merged: [UpcomingItem] = []
        for source in QueueItem.Source.allCases {
            if failed.contains(source) {
                merged += upcoming.filter { $0.source == source }
            } else {
                merged += freshBySource[source] ?? []
            }
        }
        merged = merged
            .filter { $0.airDate >= startOfToday }
            .sorted { $0.airDate < $1.airDate }
        upcoming = merged
        tonight = Self.tonightSlice(from: merged, hours: configStore.tonightHours)
        WidgetDataStore.saveUpcoming(merged)
    }

    // MARK: - Connection health

    /// Arr dots come from the queue fetch; download clients and AI are probed by `connectionMonitor`.
    /// `only` limits arr recording to the source that fetched: replaying a stored error burns 3-strike budget.
    private func updateConnectionHealth(
        errors: [QueueItem.Source: String], only: QueueItem.Source? = nil
    ) {
        for source in QueueItem.Source.allCases where only == nil || only == source {
            let service = MonitoredService.arr(source.serviceKind)
            if service.isConfigured(in: configStore) {
                ConnectionHealth.shared.record(
                    service,
                    success: errors[source] == nil,
                    detail: nil,
                    message: errors[source]
                )
            } else {
                ConnectionHealth.shared.markUnknown(service)
            }
        }
        for service in MonitoredService.probeTargets where !service.isConfigured(in: configStore) {
            ConnectionHealth.shared.markUnknown(service)
        }
        applyBreakers()
        // The probe sweep only colours dots inside the panel; opening it runs a refresh that lands here.
        guard isPanelVisible else { return }
        let inputs = buildProbeInputs()
        Task { [connectionMonitor] in
            let outcomes = await connectionMonitor.probeIfDue(inputs, force: false)
            for outcome in outcomes {
                ConnectionHealth.shared.record(
                    outcome.service,
                    success: outcome.success,
                    detail: outcome.detail,
                    message: outcome.message
                )
            }
        }
    }

    /// Probe now, bypassing the throttle, and pin the outcome without debounce — a probe of just-saved
    /// settings is proof. The dot drops to grey meanwhile so a stale result never lingers.
    private func reprobe(_ service: MonitoredService) {
        ConnectionHealth.shared.markUnknown(service)
        guard service.isConfigured(in: configStore) else { return }
        let inputs = buildProbeInputs()
        Task { [connectionMonitor] in
            let outcome = await connectionMonitor.probe(service, inputs)
            if outcome.success {
                ConnectionHealth.shared.forceOK(service, detail: outcome.detail)
            } else {
                ConnectionHealth.shared.forceDown(service, message: outcome.message ?? "")
            }
        }
    }

    private func buildProbeInputs() -> ConnectionHealthMonitor.ProbeInputs {
        var clients: [ServiceKind: ServiceConfig] = [:]
        for kind in MonitoredService.downloadClientKinds where MonitoredService.arr(kind).isConfigured(in: configStore) {
            clients[kind] = configStore.config(for: kind)
        }
        let openai = configStore.openai.isConfigured ? configStore.openai : nil
        let tmdb = configStore.tmdbApiKey.isEmpty ? nil : configStore.tmdbApiKey
        // Control-gated: a lapsed entitlement must not keep probing the user's server.
        let mediaServer = (configStore.mediaServer.isConfigured && StoreManager.shared.isPro)
            ? configStore.mediaServer : nil
        let prowlarr = MonitoredService.prowlarr.isConfigured(in: configStore)
        return .init(clients: clients, openai: openai, tmdbKey: tmdb, mediaServer: mediaServer,
                     prowlarr: prowlarr)
    }

    /// "Needs you" rows for down download clients and AI; arr issues come from `computeNeedsYou`.
    private func serviceIssueRows() -> [NeedsYouItem] {
        return MonitoredService.probeTargets.compactMap { service in
            guard case .down(let message) = ConnectionHealth.shared.state(for: service) else { return nil }
            return NeedsYouItem(serviceIssue: service, message: message)
        }
    }

    /// Same selection order as `QueueAggregator.performTorrent` / `performUsenet`.
    private func failedDownloadClientKind(for item: QueueItem) -> ServiceKind? {
        configStore.selectedDownloadClient(for: item.downloadProtocol)
    }

    /// Only unreachable/breaker-open/auth failures pin the client down. A rejection of this one item (a 404, a
    /// usenet `{status:false}`, an undecodable body) must not strip pause/resume from every row.
    private func actionFailureProvesClientDown(_ error: Error) -> Bool {
        switch error as? MediaKitError {
        case .unreachable, .breakerOpen, .unauthorized: true
        default: false
        }
    }

    // MARK: - Derived state

    static func tonightSlice(from upcoming: [UpcomingItem], hours: Int) -> [UpcomingItem] {
        // From the start of today, like the Upcoming tab: date-only movie releases parse to midnight.
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let cutoff = Date().addingTimeInterval(TimeInterval(hours) * 3600)
        // Sorted here so the banner can never disagree with the Upcoming tab's ordering.
        return upcoming
            .filter { $0.airDate >= startOfToday && $0.airDate <= cutoff }
            .sorted { $0.airDate < $1.airDate }
    }

    static func computeNeedsYou(
        queues: [QueueItem.Source: [QueueItem]],
        errors: [QueueItem.Source: String],
        health: HealthResult,
        showWarnings: Bool,
        unreachable: Set<QueueItem.Source> = []
    ) -> [NeedsYouItem] {
        // Explicit loop in `Source.allCases` order for a stable list; the equivalent lazy chain cost ~250 ms
        // to type-check.
        var result: [NeedsYouItem] = []
        for source in QueueItem.Source.allCases {
            for item in queues[source] ?? [] where item.status == .failed || item.status == .warning {
                result.append(NeedsYouItem(item))
            }
            // One entry per problem; the trailing chip names the app. An unreachable source is the calm
            // away-from-LAN case, so its fetch error is dropped.
            if let error = errors[source], !unreachable.contains(source) {
                result.append(NeedsYouItem(arrIssue: source, id: "needsyou.fetch.\(source.rawValue)", message: error))
            }
            for record in health.records(for: source) {
                guard let message = record.message, !message.isEmpty else { continue }
                guard record.type?.lowercased() == "error" || showWarnings else { continue }
                result.append(NeedsYouItem(arrIssue: source, id: "needsyou.health.\(source.rawValue).\(message)", message: message))
            }
        }
        // A pack's "Manual import required" lands once per episode, so identical rows collapse into ×N, keeping
        // the first as the tap target. Control chars separate the fields so no title can forge a collision.
        var merged: [NeedsYouItem] = []
        var indexByKey: [String: Int] = [:]
        for entry in result {
            let key = [
                entry.source?.rawValue ?? "",
                entry.service?.id ?? "",
                entry.title,
                entry.subtitle,
                entry.detailLines.joined(separator: "\u{1F}"),
            ].joined(separator: "\u{1E}")
            if let idx = indexByKey[key] {
                merged[idx].count += 1
            } else {
                indexByKey[key] = merged.count
                merged.append(entry)
            }
        }
        return merged
    }

    /// The calendar and health have their own clocks.
    public func refreshQueues() async {
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if pendingRefresh {
                pendingRefresh = false
                Task { await self.refreshQueues() }
            }
        }
        let queue = await aggregator.fetch()
        if Task.isCancelled { return }
        for source in QueueItem.Source.allCases where configuredArrs.contains(source) {
            commitQueue(queue.slice(for: source))
        }
        hasLoadedOnce = true
    }

    public func refreshQueue(source: QueueItem.Source) async {
        guard configStore.config(for: source.serviceKind).isConfigured else { return }
        let result = await aggregator.fetch(source: source)
        if Task.isCancelled { return }
        commitQueue(result)
        hasLoadedOnce = true
    }

    /// On its own loop because Servarr pushes health changes on the same socket, so the poll is a backstop.
    public func refreshHealth() async {
        let result = await aggregator.fetchHealth()
        if Task.isCancelled { return }
        health = result
        notifyNewHealthIssues(result)
        recomputeNeedsYou()
    }

    /// Errors only, never warnings: a notification stream that cries wolf gets silenced wholesale.
    private func notifyNewHealthIssues(_ result: HealthResult) {
        guard configStore.notifyHealth else {
            // Still fold the records in, so enabling the setting later announces only what breaks next.
            for source in QueueItem.Source.allCases where configuredArrs.contains(source) {
                _ = healthTracker.newIssues(for: source, records: result.records(for: source))
            }
            persistHealthTracker()
            return
        }
        for source in QueueItem.Source.allCases where configuredArrs.contains(source) {
            let errors = result.records(for: source).filter {
                $0.type?.lowercased() == "error" && $0.message?.isEmpty == false
            }
            for record in healthTracker.newIssues(for: source, records: errors) {
                coalescer.postHealthIssue(source: source, message: record.message ?? "")
            }
        }
        persistHealthTracker()
    }

    public func refreshUpcoming() async {
        let result = await aggregator.fetchUpcoming()
        if Task.isCancelled { return }
        commitUpcoming(items: result.items, failed: result.failed)
    }

    /// The single place a queue result lands, so the refresh and push paths cannot drift. Cross-source views
    /// are recomputed from stored state, not from this fetch.
    private func commitQueue(_ result: SourceQueueResult) {
        let source = result.source
        // A stream revision arrives twice (from the fetch and the stream); committing both would count
        // one failure twice towards the unreachable threshold.
        if let revision = result.revision {
            if revision.isCovered(by: committedRevision[source]) { return }
            committedRevision[source] = revision
        }
        var newErrors = errors
        newErrors[source] = result.error
        let committed = result.error != nil ? (queues[source] ?? []) : result.items
        var newQueues = queues
        newQueues[source] = committed

        notifyNewItems(source: source, items: committed, errored: result.error != nil)
        queues = newQueues
        errors = newErrors

        if let at = result.measuredAt { measuredAt[source] = at }

        var stillUnreachable = lastUnreachable
        if result.unreachable { stillUnreachable.insert(source) } else { stillUnreachable.remove(source) }
        lastUnreachable = stillUnreachable
        unreachableArrs = updateUnreachable(unreachable: stillUnreachable, only: source)
        if result.error == nil {
            lastSuccessfulRefresh = Date()
            QueueUIState.shared.pruneHidden(source: source, present: committed)
        }
        updateConnectionHealth(errors: newErrors, only: source)
        recomputeNeedsYou()
    }

    /// Queues, health and errors arrive on independent schedules, so the merge reads stored state.
    private func recomputeNeedsYou() {
        var needs = Self.computeNeedsYou(
            queues: queues,
            errors: errors,
            health: health,
            showWarnings: configStore.showWarnings,
            unreachable: lastUnreachable
        )
        needs.append(contentsOf: serviceIssueRows())
        needsYou = needs
        lastError = nil
    }

    /// `only` limits updates to the refreshed source; resetting the others would stop failures accumulating.
    private func updateUnreachable(
        unreachable: Set<QueueItem.Source>, only: QueueItem.Source? = nil
    ) -> Set<QueueItem.Source> {
        for source in QueueItem.Source.allCases where only == nil || only == source {
            guard configStore.config(for: source.serviceKind).isConfigured else {
                consecutiveFailures[source] = 0
                continue
            }
            if unreachable.contains(source) {
                consecutiveFailures[source, default: 0] += 1
            } else {
                consecutiveFailures[source] = 0
            }
        }
        var result: Set<QueueItem.Source> = []
        for source in QueueItem.Source.allCases
        where (consecutiveFailures[source] ?? 0) >= Self.unreachableThreshold {
            result.insert(source)
        }
        return result
    }

    // MARK: - Notifications

    /// Errored arrs are passed through so a transient empty result never re-notifies a still-queued item.
    private func notifyNewItems(source: QueueItem.Source, items: [QueueItem], errored: Bool) {
        guard !errored else { return }
        let newItems = notificationTracker.newItems(for: source, items: items)
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
        // A queued item is waiting behind the client's queue limit; "Continue" force-starts it.
        await runAction(item.status == .queued ? .continueDownload : .resume, on: item)
    }
    public func delete(_ item: QueueItem) async {
        await runAction(.delete, on: item)
    }

    /// A real pack's download is removed by the first call only; a virtual bundle's members are each
    /// removed from the client. `aggregator.deleteAll` infers which from the downloadIds.
    public func deleteAll(_ items: [QueueItem]) async {
        guard !items.isEmpty else { return }
        // The UI hides these controls when fully offline; this also blocks Siri / Shortcuts callers.
        guard !isFullyOffline else { return }
        guard StoreManager.shared.requirePro(.queueAction) else { return }
        do {
            try await aggregator.deleteAll(items)
            lastError = nil
            if let source = items.first?.source {
                Task { await self.refreshQueue(source: source) }
            }
        } catch {
            lastError = error.userFacingMessage
        }
    }

    private func runAction(_ action: QueueAggregator.Action, on item: QueueItem) async {
        guard !isFullyOffline else { return }
        guard StoreManager.shared.requirePro(.queueAction) else { return }
        do {
            try await aggregator.perform(action, on: item)
            lastError = nil
            // The command's effect paints the change at once; this refresh replaces it with a fact.
            Task { await self.refreshQueue(source: item.source) }
        } catch {
            let message = error.userFacingMessage
            lastError = message
            // Pin the client red only when the failure proves it down: `canControl` is client-wide, so a single
            // rejected request would strip pause/resume from every row.
            if actionFailureProvesClientDown(error), let kind = failedDownloadClientKind(for: item) {
                ConnectionHealth.shared.forceDown(.arr(kind), message: message)
            }
        }
    }
}

public struct NeedsYouItem: Identifiable, Equatable {
    public let id: String
    /// `nil` for a non-arr connection issue, identified by `service` instead.
    public let source: QueueItem.Source?
    public let service: MonitoredService?
    /// For an arr/service issue, the message itself; the trailing chip names the app.
    public let title: String
    public let subtitle: String
    public let detailLines: [String]
    public let item: QueueItem?
    /// Identical entries this row collapses; a pack warns once per episode.
    public var count: Int = 1

    public init(_ item: QueueItem) {
        self.item = item
        self.id = "needsyou.\(item.id)"
        self.source = item.source
        self.service = nil
        self.title = item.title
        self.subtitle = item.status == .warning
            ? String(localized: "queue.manualImportRequired.button", bundle: .module)
            : item.status.displayName
        self.detailLines = item.statusMessages
    }

    public init(
        arrIssue source: QueueItem.Source,
        id: String,
        message: String
    ) {
        self.item = nil
        self.id = id
        self.source = source
        self.service = nil
        self.title = message
        self.subtitle = ""
        self.detailLines = []
    }

    public init(
        serviceIssue service: MonitoredService,
        message: String
    ) {
        self.item = nil
        self.id = "needsyou.service.\(service.id)"
        self.source = nil
        self.service = service
        self.title = message
        self.subtitle = ""
        self.detailLines = []
    }
}
