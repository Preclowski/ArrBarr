import Foundation
import MediaKit

extension QueueViewModel {
    public func refresh() async {
        guard !isRefreshing else {
            pendingRefresh = .full
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
            runPendingRefresh()
        }
        async let queueResult = aggregator.fetch()
        async let upcomingResult = aggregator.fetchUpcoming()
        async let healthResult = aggregator.fetchHealth()
        let (queue, upcoming, freshHealth) = await (queueResult, upcomingResult, healthResult)
        // A cancelled task's fetches come back empty-with-no-error; committing them would blank the queue.
        if Task.isCancelled { return }
        // Health first: `commitQueue` recomputes "Needs you", which merges it.
        health = freshHealth.keepingLastGood(from: health)
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
        tonight = Self.tonightSlice(from: merged)
        WidgetDataStore.saveUpcoming(merged)
    }

    /// The calendar and health have their own clocks.
    public func refreshQueues() async {
        guard !isRefreshing else {
            if pendingRefresh == nil { pendingRefresh = .queues }
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            runPendingRefresh()
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
        health = result.keepingLastGood(from: health)
        notifyNewHealthIssues(health)
        recomputeNeedsYou()
    }

    public func refreshUpcoming() async {
        let result = await aggregator.fetchUpcoming()
        if Task.isCancelled { return }
        commitUpcoming(items: result.items, failed: result.failed)
    }

    /// The single place a queue result lands, so the refresh and push paths cannot drift. Cross-source views
    /// are recomputed from stored state, not from this fetch.
    func commitQueue(_ result: SourceQueueResult) {
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

        if result.error == nil, !removedIDs.isEmpty {
            let gone = Set(queues[source, default: []].map(\.id)).subtracting(committed.map(\.id))
            removedIDs.subtract(gone)
            leavingIDs.subtract(gone)
            slidingIDs.subtract(gone)
        }
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

    private func runPendingRefresh() {
        guard let pending = pendingRefresh else { return }
        pendingRefresh = nil
        Task { pending == .full ? await self.refresh() : await self.refreshQueues() }
    }
}
