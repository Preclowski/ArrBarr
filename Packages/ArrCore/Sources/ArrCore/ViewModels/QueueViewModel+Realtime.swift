import Foundation
import MediaKit

extension QueueViewModel {
    func bootstrapRealtime() async {
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

    /// The gateway swapped its stack; every subscription to the old one is redone.
    func demoModeChanged(_ on: Bool) async {
        await configStore.gateway.rebuild(demo: on)
        bootstrapCalendarInvalidation()
        await bootstrapRealtime()
        await refresh()
    }

    func updateLiveQueues() async {
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

    func bootstrapBreakers() {
        let changes = configStore.gateway.breakerChanges()
        breakerTask?.cancel()
        breakerTask = Task { [weak self] in
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                self.applyBreakers()
            }
        }
    }

    func applyBreakers() {
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

    /// Not throttled beyond burst collapsing: Servarr raises `HealthCheckCompleteEvent` only when it runs
    /// its own check, not per download.
    @MainActor
    private func scheduleHealthRefresh() {
        healthDebounce?.invalidate()
        healthDebounce = Self.commonModeTimer(interval: 2, repeats: false) { [weak self] in
            Task { await self?.refreshHealth() }
        }
    }

    private static let upcomingInterval: TimeInterval = 30 * 60
    /// Backstop for when Servarr's health push never arrives (older Servarr, a proxy dropping the frame).
    private static let healthInterval: TimeInterval = 15 * 60

    @MainActor
    func startAuxiliaryPolling() {
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


    /// Progress interpolation runs from this; `.distantPast` means no interpolation.
    @MainActor
    public func progressMeasuredAt(for source: QueueItem.Source) -> Date {
        measuredAt[source] ?? .distantPast
    }

    /// `.common` mode keeps firing while the menu-bar panel tracks events; `Timer.scheduledTimer`'s
    /// `.default` mode pauses during scroll.
    private static func commonModeTimer(
        interval: TimeInterval, repeats: Bool, _ fire: @escaping @MainActor @Sendable () -> Void
    ) -> Timer {
        // Added to the main run loop below, so it fires on the main thread.
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in MainActor.assumeIsolated { fire() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
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


    func startBackgroundPolling() {
        initialRefresh = Task { await self.refresh() }
    }

    /// Gated on Control here too: a lapsed entitlement leaves a configured server behind.
    func refreshMediaServerIndex() {
        let config = configStore.mediaServer
        guard StoreManager.shared.isPro else {
            MediaServerIndex.shared.clear()
            return
        }
        Task.detached(priority: .utility) {
            await MediaServerIndex.shared.refreshIfStale(config: config)
        }
    }
}
