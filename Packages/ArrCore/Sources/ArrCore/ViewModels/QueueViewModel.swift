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
    /// Sources that failed *this* fetch at the transport/gateway level (host
    /// unreachable / 502 / split-DNS). Immediate — unlike the 3-cycle-debounced
    /// `unreachableArrs` (which drives the menu-bar badge and the global offline
    /// chip) — so a section flips to the calm "can't reach — showing last state"
    /// treatment at once instead of reading as a loud error for three cycles.
    public private(set) var lastUnreachable: Set<QueueItem.Source> = []
    /// Timestamp of the last refresh in which at least one configured arr
    /// returned fresh data. Drives the "last updated X ago" tooltip on the
    /// offline indicator; `nil` until the first successful fetch.
    public private(set) var lastSuccessfulRefresh: Date?
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

    /// The arrs the user has actually configured. Drives `isFullyOffline`.
    private var configuredArrs: Set<QueueItem.Source> {
        Set(QueueItem.Source.allCases.filter {
            configStore.config(for: $0.serviceKind).isConfigured
        })
    }

    /// True when *every* configured arr is unreachable — the "I've left the
    /// home network" case. A single arr hiccup keeps this false (its own
    /// per-arr error / Needs-you row already covers that); only a blanket
    /// outage flips it. False when nothing is configured. Drives the subtle
    /// offline indicator in the header and gates mutating actions across the
    /// queue UI (controls that can't succeed without a live LAN connection).
    public var isFullyOffline: Bool {
        let configured = configuredArrs
        return !configured.isEmpty && configured.isSubset(of: unreachableArrs)
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
    /// Actively probes the non-arr services (download clients + AI) the queue
    /// fetch never touches, throttled internally to once a minute.
    private let connectionMonitor = ConnectionHealthMonitor()
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
        // Cold-start with the last-known "Upcoming" snapshot so the week's
        // schedule is on screen immediately — including when the arrs are
        // unreachable (away from the home LAN). The first successful refresh
        // replaces it. Skipped in demo mode (which seeds its own data).
        if autostart, !DemoMode.isActive {
            let cached = WidgetDataStore.loadUpcoming()
            if !cached.isEmpty {
                self.upcoming = cached
                self.tonight = Self.tonightSlice(from: cached, hours: configStore.tonightHours)
            }
        }
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
        //
        // Debounced for the same reason as the download-client probes below:
        // the Settings fields write to `ConfigStore` per keystroke, so typing
        // `http://nas:8989` emitted ~15 configs — each one a full teardown and
        // re-dial of that arr's SignalR connection against a half-typed host,
        // all of them overlapping inside `reconfigure`.
        Publishers.CombineLatest4(
            configStore.$sonarr, configStore.$radarr,
            configStore.$lidarr, configStore.$whisparr
        )
        .dropFirst()
        .removeDuplicates { $0 == $1 }
        .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
        .sink { [weak self] sonarr, radarr, lidarr, whisparr in
            Task { [weak self] in
                await self?.realtime.reconfigure(
                    sonarr: sonarr, radarr: radarr,
                    lidarr: lidarr, whisparr: whisparr
                )
            }
        }
        .store(in: &intervalObservers)

        // Re-probe a download client / AI service the moment its connection
        // details change, so the status dot reflects the new credentials
        // within seconds. The throttled sweep alone needs `downThreshold`
        // failed sweeps a minute apart to flip a dot — a bad edit would stay
        // green for minutes. Debounced so per-keystroke config writes from
        // the Settings fields don't fire a probe per character.
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

        // A successful "Test Connection" in Settings posts this — refresh now
        // so a freshly-saved key clears any stale per-arr error immediately.
        NotificationCenter.default.publisher(for: .arrBarrConfigValidated)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refresh() }
            }
            .store(in: &intervalObservers)
    }

    /// `isolated` so the body runs on the main actor: a plain `deinit` is
    /// nonisolated and can neither read the timer properties nor legally call
    /// `invalidate()`, which Foundation requires on the run loop that installed
    /// the timer (`RunLoop.main`, see `commonModeTimer`).
    isolated deinit {
        Task { [realtime] in await realtime.shutdown() }
        // A scheduled `Timer` is owned by the run loop, not by us — dropping
        // the view-model doesn't stop it. Without these, every discarded
        // instance leaves timers firing on `RunLoop.main` forever, each
        // retaining its closure (and re-arming the poll cadence) for the life
        // of the process.
        foregroundTimer?.invalidate()
        backgroundTimer?.invalidate()
        realtimeDebounce?.invalidate()
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
        realtimeDebounce = Self.commonModeTimer(interval: 0.25, repeats: false) { [weak self] in
            Task { await self?.refresh() }
        }
    }
    @MainActor private var realtimeDebounce: Timer?

    /// Timer registered in `.common` run loop mode so it keeps firing while the
    /// menu-bar panel is tracking events — a `.default`-mode timer (what
    /// `Timer.scheduledTimer` installs) pauses during scroll/interaction. Paired
    /// with the AppDelegate's App Nap opt-out, this is what makes the poll
    /// cadence actually hold instead of silently stretching out.
    private static func commonModeTimer(
        interval: TimeInterval, repeats: Bool, _ fire: @escaping () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in fire() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

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
        foregroundTimer = Self.commonModeTimer(interval: interval, repeats: true) { [weak self] in
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
        backgroundTimer = Self.commonModeTimer(interval: interval, repeats: true) { [weak self] in
            Task { await self?.refresh() }
        }
    }

    private func restartBackgroundPolling() {
        backgroundTimer?.invalidate()
        let interval = configStore.backgroundInterval
        guard interval > 0 else { return }
        backgroundTimer = Self.commonModeTimer(interval: interval, repeats: true) { [weak self] in
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
            self.lastUnreachable = []
            self.needsYou = Self.computeNeedsYou(queues: self.queues, errors: [:], health: DemoMocks.health, showWarnings: configStore.showWarnings)
            for service in MonitoredService.allCases {
                ConnectionHealth.shared.forceOK(service, detail: nil)
            }
            self.lastError = nil
            self.lastSuccessfulRefresh = Date()
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
            return applyOverrides(to: fresh, previous: self.queues[source] ?? [])
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
        // Per-source keep-last-good for the calendar. A source whose calendar
        // fetch FAILED keeps its previously-known entries (so a blocked Radarr
        // keeps its movies in the merged "Upcoming"); a reachable source — even
        // one that genuinely returned nothing — replaces its own slice. Without
        // this, one unreachable arr silently erased its half of the schedule
        // AND the cache then saved the gutted result.
        let freshUpcomingBySource = Dictionary(grouping: upcoming.items, by: { $0.source })
        let startOfTodayUpcoming = Calendar.current.startOfDay(for: Date())
        var mergedUpcoming: [UpcomingItem] = []
        for source in QueueItem.Source.allCases {
            if upcoming.failed.contains(source) {
                mergedUpcoming += self.upcoming.filter { $0.source == source }
            } else {
                mergedUpcoming += freshUpcomingBySource[source] ?? []
            }
        }
        mergedUpcoming = mergedUpcoming
            .filter { $0.airDate >= startOfTodayUpcoming }
            .sorted { $0.airDate < $1.airDate }
        self.upcoming = mergedUpcoming
        self.tonight = Self.tonightSlice(from: mergedUpcoming, hours: configStore.tonightHours)
        // Persist so cold-start / offline shows the week's schedule even when the
        // arrs are unreachable — now with the failed sources' last-known entries
        // preserved, not gutted.
        WidgetDataStore.saveUpcoming(mergedUpcoming)
        self.health = health
        self.lastUnreachable = queue.unreachableSources
        self.unreachableArrs = updateUnreachable(unreachable: queue.unreachableSources)
        // Stamp the freshness clock whenever at least one configured arr
        // returned without error — that's the data whose age the offline
        // indicator reports.
        if configuredArrs.contains(where: { newErrors[$0] == nil }) {
            lastSuccessfulRefresh = Date()
        }
        updateConnectionHealth(errors: newErrors)
        var needs = Self.computeNeedsYou(queues: newQueues, errors: newErrors, health: health, showWarnings: configStore.showWarnings, unreachable: queue.unreachableSources)
        needs.append(contentsOf: serviceIssueRows())
        self.needsYou = needs
        self.lastError = nil
    }

    // MARK: - Connection health

    /// Drives the unified `ConnectionHealth` state each refresh.
    ///  - Arrs are health-checked from the live queue fetch (a real probe every
    ///    cycle): configured + no error → ok; configured + error → failure
    ///    (debounced); unconfigured → unknown.
    ///  - Download clients + AI services aren't fetched here, so they're probed
    ///    by `connectionMonitor` (throttled to once a minute). Unconfigured ones
    ///    are reset to unknown so a stale result doesn't linger.
    private func updateConnectionHealth(errors: [QueueItem.Source: String]) {
        for source in QueueItem.Source.allCases {
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

    /// Probe one service right now, bypassing the sweep throttle, and pin the
    /// outcome immediately (no debounce — a deliberate probe of just-saved
    /// settings is proof, the same way a manual "Test Connection" is). Called
    /// when the service's connection details change in Settings. While the
    /// probe is in flight the dot drops to grey so a stale green/red from the
    /// previous credentials never lingers.
    private func reprobe(_ service: MonitoredService) {
        ConnectionHealth.shared.markUnknown(service)
        guard service.isConfigured(in: configStore), !DemoMode.isActive else { return }
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

    /// Build the Sendable probe snapshot for the configured download clients +
    /// AI services, read on the main actor.
    private func buildProbeInputs() -> ConnectionHealthMonitor.ProbeInputs {
        var clients: [ServiceKind: ServiceConfig] = [:]
        for kind in MonitoredService.downloadClientKinds where MonitoredService.arr(kind).isConfigured(in: configStore) {
            clients[kind] = configStore.config(for: kind)
        }
        let openai = configStore.openai.isConfigured ? configStore.openai : nil
        let tmdb = configStore.tmdbApiKey.isEmpty ? nil : configStore.tmdbApiKey
        return .init(clients: clients, openai: openai, tmdbKey: tmdb)
    }

    /// "Needs you" rows for the non-arr services currently `.down` (download
    /// clients + AI). Arr issues are already surfaced by `computeNeedsYou`, so
    /// these never double-report.
    private func serviceIssueRows() -> [NeedsYouItem] {
        return MonitoredService.probeTargets.compactMap { service in
            guard case .down(let message) = ConnectionHealth.shared.state(for: service) else { return nil }
            return NeedsYouItem(serviceIssue: service, message: message)
        }
    }

    /// The configured download client that backs `item`, used to pin it `.down`
    /// when a queue action against it fails. Same client-selection order as
    /// `QueueAggregator.performTorrent` / `performUsenet` (via the shared
    /// `ConfigStore.selectedDownloadClient`).
    private func failedDownloadClientKind(for item: QueueItem) -> ServiceKind? {
        configStore.selectedDownloadClient(for: item.downloadProtocol)
    }

    /// Whether a failed queue action proves the download *client itself* is
    /// unreachable / misconfigured — and so may be pinned `.down` for the whole
    /// queue — versus a reachable client that simply rejected this one request.
    ///
    /// Only genuine client-level failures qualify:
    ///   - `.transport` — the request never reached the client (connection
    ///     refused, timed out, no route): truly unreachable.
    ///   - `.status(401/403)` — the client answered but rejected our
    ///     credentials: a persistent misconfiguration every action will hit.
    ///
    /// Everything else means the client answered and rejected *this* item — a
    /// 404/409 for a download it already completed and removed, SAB/NZBGet's
    /// `{status:false}` (their own `…Error.actionFailed`, not an `HTTPError`),
    /// an undecodable body — or the failure is item-local (no download id,
    /// unknown protocol). None of those say the client went away, so they must
    /// NOT strip the pause/resume affordance from every other row.
    private func actionFailureProvesClientDown(_ error: Error) -> Bool {
        guard let http = error as? HTTPError else { return false }
        switch http {
        case .transport:
            return true
        case .status(let code, _):
            return code == 401 || code == 403
        default:
            return false
        }
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
        health: HealthResult,
        showWarnings: Bool,
        unreachable: Set<QueueItem.Source> = []
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
            //  • health checks the arr itself reports. Errors always surface;
            //    warnings/notices (broken indexer, update available, …) surface
            //    only when the user opted into "Show warnings" — otherwise this
            //    list stays errors-only and isn't drowned in noise.
            // ONE entry per problem — NOT grouped by app (the trailing chip names
            // it, so the title must not repeat the app name) or by severity (each
            // row carries its own severity icon). An *unreachable* source
            // (transport / 502 / split-DNS) is the calm "you've left the LAN"
            // case, not an actionable problem, so its fetch error is dropped here.
            if let error = errors[source], !unreachable.contains(source) {
                result.append(NeedsYouItem(arrIssue: source, id: "needsyou.fetch.\(source.rawValue)", message: error, severity: .error))
            }
            for record in health.records(for: source) {
                guard let message = record.message, !message.isEmpty else { continue }
                let severity: NeedsYouItem.Severity = switch record.type?.lowercased() {
                case "error": .error
                case "warning": .warning
                default: .notice
                }
                // Errors always; warnings/notices only when the user opted in.
                guard severity == .error || showWarnings else { continue }
                result.append(NeedsYouItem(arrIssue: source, id: "needsyou.health.\(source.rawValue).\(message)", message: message, severity: severity))
            }
        }
        // Collapse byte-identical entries into one row carrying a ×N count. A
        // pack's "Manual import required" warning lands once per EPISODE, so a
        // 24-episode season would otherwise be 24 identical rows. Group by the
        // rendered content (source/service + title + subtitle + detailLines),
        // keep the FIRST — its id/item is the stable representative the tap
        // handler opens — and bump its count. Control chars separate the fields
        // so no real title can forge a collision.
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

    /// Returns the set of arrs that have failed *at the transport level* (host
    /// unreachable) for at least `unreachableThreshold` consecutive refresh
    /// cycles. A source that responded — even with an HTTP error — resets its
    /// counter, so an outage (502/500) never reads as "offline". Drives
    /// `isFullyOffline`.
    private func updateUnreachable(unreachable: Set<QueueItem.Source>) -> Set<QueueItem.Source> {
        var result: Set<QueueItem.Source> = []
        for source in QueueItem.Source.allCases {
            guard configStore.config(for: source.serviceKind).isConfigured else {
                consecutiveFailures[source] = 0
                continue
            }
            if unreachable.contains(source) {
                consecutiveFailures[source, default: 0] += 1
                if (consecutiveFailures[source] ?? 0) >= Self.unreachableThreshold {
                    result.insert(source)
                }
            } else {
                consecutiveFailures[source] = 0
            }
        }
        return result
    }

    /// Lays the user's in-flight optimistic actions over a freshly fetched
    /// source queue. Two jobs:
    ///
    ///  1. **Present items** — replay a pending status override (pause→paused,
    ///     resume→downloading) until the arr's own fetch reports the same
    ///     status, then drop the override; a `.deleted` override hides the row.
    ///  2. **Vanished items** — re-inject a "ghost". When the user force-starts
    ///     a *queued* item, the arr briefly drops it from `/queue` entirely
    ///     (it sits between the download client's queue and its active list)
    ///     and re-adds it ~10–15 s later as downloading. Without this the row
    ///     blinks out and pops back — an ugly hole. So any item still carrying
    ///     a live *status* override that's missing from the fresh fetch is
    ///     re-inserted at roughly its previous position, in its optimistic
    ///     state, until the override expires or the arr returns it. Never for
    ///     `.deleted` (those should stay gone) and never past the 30 s expiry
    ///     (so a genuinely-removed item isn't held on screen forever).
    private func applyOverrides(to fresh: [QueueItem], previous: [QueueItem]) -> [QueueItem] {
        let now = Date()
        var result: [QueueItem] = fresh.compactMap { item in
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
        // Bridge the queued→active gap: keep a just-actioned row on screen while
        // the arr momentarily drops it from its queue.
        let freshIds = Set(fresh.map { $0.id })
        for (idx, prev) in previous.enumerated() where !freshIds.contains(prev.id) {
            guard let override = optimisticOverrides[prev.id] else { continue }
            guard override.expiry >= now, case .status(let status) = override.kind else {
                // Expired status override on a vanished row → stop tracking it.
                if override.expiry < now { optimisticOverrides.removeValue(forKey: prev.id) }
                continue
            }
            var ghost = prev
            ghost.status = status
            result.insert(ghost, at: min(idx, result.count))
        }
        return result
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
        // Safety net for the away-from-LAN case: the UI hides these controls
        // when fully offline, but block here too so any other caller (Siri /
        // Shortcuts) can't fire an action that has no chance of reaching the
        // arr.
        guard !isFullyOffline else { return }
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
        // See `deleteAll` — defend the same away-from-LAN case for single-item
        // pause / resume / delete.
        guard !isFullyOffline else { return }
        guard StoreManager.shared.requirePro(.queueAction) else { return }
        do {
            try await aggregator.perform(action, on: item)
            lastError = nil
            applyOptimisticUpdate(action, on: item)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            // Pin the client red ONLY when the failure proves the client itself
            // is unreachable / misconfigured — NOT when a reachable client
            // merely rejected THIS request (e.g. resuming a download it has
            // already completed and removed). `canControl` reads a client-wide
            // health state, so a spurious `.down` strips the hover pause/resume
            // control from *every* queue row at once — the exact symptom of
            // clicking resume on a churning queue until one stale item's
            // rejection blanked the affordance everywhere.
            if actionFailureProvesClientDown(error), let kind = failedDownloadClientKind(for: item) {
                ConnectionHealth.shared.forceDown(.arr(kind), message: message)
            }
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
    /// Per-entry severity — drives the leading icon (the list isn't grouped by
    /// severity; each row carries its own).
    public enum Severity: Equatable { case error, warning, notice }

    public let id: String
    /// The arr this row belongs to — `nil` for a non-arr connection issue
    /// (download client / AI), which is identified by `service` instead.
    public let source: QueueItem.Source?
    /// Set only for a non-arr connection issue; drives the chip icon/label and
    /// tells tap handlers there's no arr queue page to open.
    public let service: MonitoredService?
    /// For a queue item, the media title. For an arr/service issue, the issue
    /// MESSAGE itself — the app is identified by the trailing chip (icon +
    /// name), so the title must not repeat the app name.
    public let title: String
    /// Status name for a queue item (Failed / Manual import required); empty for
    /// arr/service issues (their message is the title, severity is the icon).
    public let subtitle: String
    /// Extra "why" lines for a queue item (the arr's status messages). Empty for
    /// arr/service issues — their single message is the title.
    public let detailLines: [String]
    public let severity: Severity
    /// The underlying queue item when this row represents one; `nil` for
    /// arr-level issues (connection / health problems) that have no queue row.
    public let item: QueueItem?
    /// How many byte-identical entries this row collapses (1 = un-merged). A
    /// season pack surfaces one "Manual import required" warning per EPISODE, so
    /// `computeNeedsYou` dedupes identical rows and bumps this; the view shows
    /// "×N" when > 1.
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
        self.severity = item.status == .failed ? .error : .warning
    }

    /// A single arr-level problem (a reachable fetch error, or one health-check
    /// message). One entry per message — not grouped by app or severity.
    public init(
        arrIssue source: QueueItem.Source,
        id: String,
        message: String,
        severity: Severity
    ) {
        self.item = nil
        self.id = id
        self.source = source
        self.service = nil
        self.title = message
        self.subtitle = ""
        self.detailLines = []
        self.severity = severity
    }

    /// A non-arr connection issue (a download client or AI service is
    /// unreachable / misconfigured). The message is the title; the chip names it.
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
        self.severity = .error
    }
}
