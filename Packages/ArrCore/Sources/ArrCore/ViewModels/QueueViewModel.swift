import Foundation
import SwiftUI
import UserNotifications
import os

@Observable
public final class QueueViewModel {
    public internal(set) var queues: [QueueItem.Source: [QueueItem]] = [:]
    public internal(set) var errors: [QueueItem.Source: String] = [:]

    public internal(set) var upcoming: [UpcomingItem] = []
    public internal(set) var tonight: [UpcomingItem] = []
    public internal(set) var needsYou: [NeedsYouItem] = []
    public internal(set) var unreachableArrs: Set<QueueItem.Source> = []
    /// Sources whose fetch failed at the transport level this cycle. Not debounced like `unreachableArrs`,
    /// so a section shows the calm "can't reach" state at once instead of an error for three cycles.
    public internal(set) var lastUnreachable: Set<QueueItem.Source> = []
    /// Last refresh in which any configured arr returned fresh data; `nil` until the first success.
    public internal(set) var lastSuccessfulRefresh: Date?
    /// Reset every time the popover closes.
    public private(set) var tonightExpanded: Bool = false

    public func setTonightExpanded(_ expanded: Bool) { tonightExpanded = expanded }

    public func items(for source: QueueItem.Source) -> [QueueItem] {
        let items = queues[source, default: []]
        return removedIDs.isEmpty ? items : items.filter { !removedIDs.contains($0.id) }
    }

    public func error(for source: QueueItem.Source) -> String? {
        errors[source]
    }

    /// Popover open or detached window visible. Calendar, health dots and probes render only in the panel,
    /// so they are not fetched while it is hidden.
    var isPanelVisible = false

    var configuredArrs: Set<QueueItem.Source> {
        Set(QueueItem.Source.allCases.filter {
            // An arr without its key is registered disabled; counting it would read as a failed refresh.
            configStore.config(for: $0.serviceKind).isVisible
        })
    }

    /// Every configured arr is unreachable — the user has left the home LAN. False when nothing is configured.
    public var isFullyOffline: Bool {
        let configured = configuredArrs
        return !configured.isEmpty && configured.isSubset(of: unreachableArrs)
    }

    public internal(set) var health: HealthResult = .empty
    public internal(set) var isLoading = false
    /// Set after the first `refresh()` settles; later polls never show the loading spinner, even on an empty queue.
    public internal(set) var hasLoadedOnce = false {
        didSet { if hasLoadedOnce, !oldValue { Self.logFirstLoad() } }
    }
    public internal(set) var lastError: String?
    /// Rows playing the delete animation: `leavingIDs` drives the tint, `slidingIDs` the slide. Two sets because
    /// each needs its own `withAnimation` curve. Kept until the server drops them, so a row never slides back.
    public internal(set) var leavingIDs: Set<QueueItem.ID> = []
    public internal(set) var slidingIDs: Set<QueueItem.ID> = []
    /// Deleted rows hidden ahead of the server, so a commit that still lists them can't bring them back.
    var removedIDs: Set<QueueItem.ID> = []

    let aggregator: QueueDataProviding
    let configStore: ConfigStore
    let coalescer: NotificationCoalescer
    let connectionMonitor = ConnectionHealthMonitor()
    var queueUpdatesTask: Task<Void, Never>?
    var committedRevision: [QueueItem.Source: QueueRevision] = [:]
    var liveQueuesStarted = false
    /// The streams start after it so their first tick finds a fresh reading instead of a second fetch.
    var initialRefresh: Task<Void, Never>?
    private var configObservers: [Task<Void, Never>] = []
    private var configValidatedTask: Task<Void, Never>?
    private var artworkChangedTask: Task<Void, Never>?
    public internal(set) var isRefreshing = false
    enum PendingRefresh { case queues, full }
    /// A refresh requested mid-flight re-runs once from the in-flight `defer`, so a SignalR push is never dropped.
    /// A full one wins over a queues-only one, whichever is running.
    var pendingRefresh: PendingRefresh?
    @ObservationIgnored
    lazy var notificationTracker = Self.loadNotificationTracker(from: notificationDefaults)

    private let notificationDefaults: UserDefaults
    private static let notificationTrackerKey = "ArrBarr.notificationTrackerState"

    private static func loadNotificationTracker(from defaults: UserDefaults) -> QueueNotificationTracker {
        guard let data = defaults.data(forKey: notificationTrackerKey),
              let tracker = try? JSONDecoder().decode(QueueNotificationTracker.self, from: data)
        else { return QueueNotificationTracker() }
        return tracker
    }

    func persistNotificationTracker() {
        guard let data = try? JSONEncoder().encode(notificationTracker) else { return }
        notificationDefaults.set(data, forKey: Self.notificationTrackerKey)
    }

    @ObservationIgnored
    lazy var healthTracker: HealthNotificationTracker = {
        guard let data = notificationDefaults.data(forKey: Self.healthTrackerKey),
              let tracker = try? JSONDecoder().decode(HealthNotificationTracker.self, from: data)
        else { return HealthNotificationTracker() }
        return tracker
    }()
    private static let healthTrackerKey = "ArrBarr.healthNotificationTrackerState"

    func persistHealthTracker() {
        guard let data = try? JSONEncoder().encode(healthTracker) else { return }
        notificationDefaults.set(data, forKey: Self.healthTrackerKey)
    }

    /// Consecutive failed queue fetches; an arr is marked unreachable only after 3, to ride out blips.
    var consecutiveFailures: [QueueItem.Source: Int] = [:]
    static let unreachableThreshold = 3


    public var activeCount: Int {
        queues.values.lazy.flatMap { $0 }.filter { $0.status != .completed && !self.removedIDs.contains($0.id) }.count
    }

    public func fireTestNotification() {
        coalescer.postTest()
    }

    @ObservationIgnored var realtimeTask: Task<Void, Never>?
    @ObservationIgnored var breakerTask: Task<Void, Never>?
    @ObservationIgnored var invalidationObserver: NotificationCenter.ObservationToken?

    /// Shared by the AppDelegate and the `MenuBarExtra` scene so they see one snapshot and don't double-poll.
    public static let shared = QueueViewModel(configStore: .shared)

    public init(
        configStore: ConfigStore,
        notificationDefaults: UserDefaults = DemoMode.profileDefaults
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
                self.tonight = Self.tonightSlice(from: cached)
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

        // An arr added or removed starts or stops its queue stream. Probes are debounced because Settings
        // writes to `ConfigStore` per keystroke.
        let store = configStore
        for source in QueueItem.Source.allCases {
            configObservers.append(observeChanges(of: { store.config(for: source).isVisible }) { [weak self] _ in
                Task { await self?.updateLiveQueues() }
            })
        }
        func reprobe(_ service: MonitoredService, when value: @escaping @MainActor @Sendable () -> some Equatable & Sendable) {
            configObservers.append(observeChanges(of: value, debounce: .seconds(1.5)) { [weak self] _ in self?.reprobe(service) })
        }
        for kind in MonitoredService.downloadClientKinds { reprobe(.arr(kind)) { store.config(for: kind) } }
        reprobe(.openai) { store.openai }
        reprobe(.tmdb) { store.tmdbApiKey }
        reprobe(.mediaServer) { store.mediaServer }
        reprobe(.prowlarr) { store.prowlarr }

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
        configObservers.forEach { $0.cancel() }
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

    @ObservationIgnored @MainActor var upcomingRefreshTask: Task<Void, Never>?
    @ObservationIgnored @MainActor var upcomingRefreshAgain = false
    @MainActor var healthDebounce: Timer?
    @MainActor var upcomingTimer: Timer?
    @MainActor var healthTimer: Timer?
    @MainActor var measuredAt: [QueueItem.Source: Date] = [:]

    /// One raw page; pairing and folding run over all loaded pages in `HistoryFeed`.
    func fetchHistory(for source: QueueItem.Source, page: Int, scope: HistoryScope? = nil) async -> HistoryResult {
        let pageSize = HistoryFeed.pageSize
        return await aggregator.fetchHistory(for: source, page: page, pageSize: pageSize, scope: scope)
    }

    /// Kept across opens: the popover rebuilds its History view every time.
    @ObservationIgnored private var historyFeeds: [HistoryFeedKey: HistoryFeed] = [:]

    private struct HistoryFeedKey: Hashable {
        let sources: [QueueItem.Source]
        let scope: HistoryScope?
    }

    /// `scope` narrows the feed to one detail's subject; nil is the arr-wide feed.
    func historyFeed(for sources: [QueueItem.Source], scope: HistoryScope? = nil) -> HistoryFeed {
        let key = HistoryFeedKey(sources: sources, scope: scope)
        if let cached = historyFeeds[key] { return cached }
        let feed = HistoryFeed(sources: sources) { [weak self] source, page in
            await self?.fetchHistory(for: source, page: page, scope: scope) ?? HistoryResult(items: [], error: nil)
        }
        // One detail's history is on screen at a time; older per-title feeds would pile up for the app's lifetime.
        if scope != nil { historyFeeds = historyFeeds.filter { $0.key.scope == nil } }
        historyFeeds[key] = feed
        return feed
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
}
