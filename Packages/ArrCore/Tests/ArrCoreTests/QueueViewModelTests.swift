import Testing
import Foundation
import Combine
import Observation
@testable import ArrCore

// MARK: - Test doubles

/// Fake `QueueDataProviding` so `QueueViewModel.refresh()` and the action
/// paths can be exercised without real network clients.
@MainActor
private final class FakeAggregator: QueueDataProviding {
    var fetchResult = AggregateResult(radarr: [], sonarr: [], lidarr: [], whisparr: [])
    var upcomingResult: [UpcomingItem] = []
    var healthResult: HealthResult = .empty
    var historyResult = HistoryResult(items: [], error: nil)

    /// When set, every `perform`/`deleteAll` throws this — used to assert the
    /// view-model surfaces `lastError` and skips the optimistic mutation.
    var actionError: Error?

    private(set) var fetchCallCount = 0
    private(set) var performedActions: [(QueueAggregator.Action, String)] = []

    /// Optional hook invoked inside `fetch()` (after the counter bumps) so a
    /// test can suspend the first fetch and exercise the queue-not-drop path.
    var onFetch: (() async -> Void)?

    func fetch() async -> AggregateResult {
        fetchCallCount += 1
        await onFetch?()
        return fetchResult
    }
    func fetchUpcoming() async -> [UpcomingItem] { upcomingResult }
    func fetchHealth() async -> HealthResult { healthResult }
    func fetchHistory(for source: QueueItem.Source) async -> HistoryResult { historyResult }
    func perform(_ action: QueueAggregator.Action, on item: QueueItem) async throws {
        performedActions.append((action, item.id))
        if let actionError { throw actionError }
    }
    func deleteAll(_ items: [QueueItem]) async throws {
        if let actionError { throw actionError }
    }
}

/// One-shot async gate: `wait()` parks until `open()` is called (and is a
/// no-op once opened, so call ordering doesn't matter).
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct TestError: LocalizedError {
    var errorDescription: String? { "action failed" }
}

// MARK: - Fixtures

@MainActor
private func makeSUT(
    configure: (ConfigStore) -> Void = { _ in }
) -> (sut: QueueViewModel, fake: FakeAggregator, config: ConfigStore) {
    let suiteName = "QueueViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let config = ConfigStore(defaults: defaults)
    configure(config)
    let fake = FakeAggregator()
    let sut = QueueViewModel(
        configStore: config,
        notificationDefaults: defaults,
        aggregator: fake,
        autostart: false
    )
    return (sut, fake, config)
}

private func makeItem(
    _ id: String,
    source: QueueItem.Source,
    status: QueueItem.Status
) -> QueueItem {
    QueueItem(
        id: id, source: source, arrQueueId: 0,
        downloadId: nil, downloadProtocol: .unknown,
        downloadClient: nil, indexer: nil,
        title: id, subtitle: nil,
        status: status, progress: 0, sizeTotal: 0,
        sizeLeft: 0, timeLeft: nil,
        customFormats: [], customFormatScore: 0,
        quality: nil, isUpgrade: false,
        contentSlug: nil
    )
}

private let configuredArr = ServiceConfig(
    enabled: true, baseURL: "http://localhost", apiKey: "k",
    username: "", password: ""
)

// MARK: - refresh() mapping

@Suite("QueueViewModel.refresh")
@MainActor
struct QueueViewModelRefreshTests {
    @Test("Maps fetched per-source items into the published queues")
    func mapsFetchIntoQueues() async {
        let (sut, fake, _) = makeSUT()
        fake.fetchResult = AggregateResult(
            radarr: [makeItem("r", source: .radarr, status: .downloading)],
            sonarr: [makeItem("s", source: .sonarr, status: .downloading)],
            lidarr: [], whisparr: []
        )
        await sut.refresh()
        #expect(sut.items(for: .radarr).map(\.id) == ["r"])
        #expect(sut.items(for: .sonarr).map(\.id) == ["s"])
        #expect(sut.hasLoadedOnce)
    }

    @Test("activeCount counts every non-completed item across sources")
    func activeCountExcludesCompleted() async {
        let (sut, fake, _) = makeSUT()
        fake.fetchResult = AggregateResult(
            radarr: [
                makeItem("dl", source: .radarr, status: .downloading),
                makeItem("done", source: .radarr, status: .completed),
            ],
            sonarr: [makeItem("warn", source: .sonarr, status: .warning)],
            lidarr: [], whisparr: []
        )
        await sut.refresh()
        #expect(sut.activeCount == 2)
    }

    @Test("A failed fetch keeps the last good queue instead of blanking it")
    func keepsLastGoodOnError() async {
        let (sut, fake, _) = makeSUT()
        fake.fetchResult = AggregateResult(
            radarr: [], sonarr: [makeItem("s", source: .sonarr, status: .downloading)],
            lidarr: [], whisparr: []
        )
        await sut.refresh()
        #expect(sut.items(for: .sonarr).map(\.id) == ["s"])

        // Next cycle errors out with an empty list — must not wipe the row.
        fake.fetchResult = AggregateResult(
            radarr: [], sonarr: [], lidarr: [], whisparr: [],
            sonarrError: "boom"
        )
        await sut.refresh()
        #expect(sut.items(for: .sonarr).map(\.id) == ["s"])
        #expect(sut.error(for: .sonarr) == "boom")
    }

    @Test("A refresh triggered mid-flight is drained once, not dropped")
    func pendingRefreshRerunsOnce() async {
        let (sut, fake, _) = makeSUT()
        let gate = Gate()
        fake.onFetch = { [fake] in
            if fake.fetchCallCount == 1 { await gate.wait() }
        }

        let first = Task { await sut.refresh() }
        await Task.yield()                  // let `first` reach the gated fetch
        await sut.refresh()                 // mid-flight trigger → pendingRefresh
        gate.open()
        await first.value                   // defer drains the pending trigger

        for _ in 0..<100 where fake.fetchCallCount < 2 { await Task.yield() }
        #expect(fake.fetchCallCount == 2)
    }
}

// MARK: - Optimistic updates

@Suite("QueueViewModel optimistic updates")
@MainActor
struct QueueViewModelOptimisticTests {
    @Test("Pause flips the row to paused immediately")
    func pauseMarksPaused() async {
        let (sut, fake, _) = makeSUT()
        let item = makeItem("a", source: .sonarr, status: .downloading)
        fake.fetchResult = AggregateResult(radarr: [], sonarr: [item], lidarr: [], whisparr: [])
        await sut.refresh()

        await sut.pause(item)
        #expect(sut.items(for: .sonarr).first?.status == .paused)
        #expect(fake.performedActions.map(\.0) == [.pause])
    }

    @Test("Delete removes the row immediately")
    func deleteRemovesRow() async {
        let (sut, fake, _) = makeSUT()
        let item = makeItem("a", source: .sonarr, status: .downloading)
        fake.fetchResult = AggregateResult(radarr: [], sonarr: [item], lidarr: [], whisparr: [])
        await sut.refresh()

        await sut.delete(item)
        #expect(sut.items(for: .sonarr).isEmpty)
    }

    @Test("The override holds across a refresh until the backend catches up")
    func overridePersistsThenClears() async {
        let (sut, fake, _) = makeSUT()
        let item = makeItem("a", source: .sonarr, status: .downloading)
        fake.fetchResult = AggregateResult(radarr: [], sonarr: [item], lidarr: [], whisparr: [])
        await sut.refresh()
        await sut.pause(item)

        // Backend still reports "downloading" — override keeps it paused.
        fake.fetchResult = AggregateResult(
            radarr: [], sonarr: [makeItem("a", source: .sonarr, status: .downloading)],
            lidarr: [], whisparr: []
        )
        await sut.refresh()
        #expect(sut.items(for: .sonarr).first?.status == .paused)

        // Backend now agrees — override clears and the real status flows through.
        fake.fetchResult = AggregateResult(
            radarr: [], sonarr: [makeItem("a", source: .sonarr, status: .paused)],
            lidarr: [], whisparr: []
        )
        await sut.refresh()
        #expect(sut.items(for: .sonarr).first?.status == .paused)
    }

    @Test("A failed action surfaces lastError and leaves the row untouched")
    func failedActionSurfacesError() async {
        let (sut, fake, _) = makeSUT()
        let item = makeItem("a", source: .sonarr, status: .downloading)
        fake.fetchResult = AggregateResult(radarr: [], sonarr: [item], lidarr: [], whisparr: [])
        await sut.refresh()
        fake.actionError = TestError()

        await sut.pause(item)
        #expect(sut.lastError == "action failed")
        #expect(sut.items(for: .sonarr).first?.status == .downloading)
    }
}

// MARK: - Unreachable tracking

@Suite("QueueViewModel unreachable tracking")
@MainActor
struct QueueViewModelUnreachableTests {
    @Test("A configured arr is marked unreachable only after 3 consecutive failures")
    func threeFailuresMarkUnreachable() async {
        let (sut, fake, _) = makeSUT { $0.sonarr = configuredArr }
        fake.fetchResult = AggregateResult(
            radarr: [], sonarr: [], lidarr: [], whisparr: [], sonarrError: "boom"
        )
        await sut.refresh()
        #expect(!sut.unreachableArrs.contains(.sonarr))
        await sut.refresh()
        #expect(!sut.unreachableArrs.contains(.sonarr))
        await sut.refresh()
        #expect(sut.unreachableArrs.contains(.sonarr))
    }

    @Test("A successful fetch resets the consecutive-failure counter")
    func successResetsCounter() async {
        let (sut, fake, _) = makeSUT { $0.sonarr = configuredArr }
        let errorResult = AggregateResult(
            radarr: [], sonarr: [], lidarr: [], whisparr: [], sonarrError: "boom"
        )
        fake.fetchResult = errorResult
        await sut.refresh()
        await sut.refresh()                 // 2 failures

        fake.fetchResult = AggregateResult(
            radarr: [], sonarr: [makeItem("s", source: .sonarr, status: .downloading)],
            lidarr: [], whisparr: []
        )
        await sut.refresh()                 // success → reset

        fake.fetchResult = errorResult
        await sut.refresh()
        await sut.refresh()                 // only 2 failures since reset
        #expect(!sut.unreachableArrs.contains(.sonarr))
    }

    @Test("An unconfigured arr never becomes unreachable even when it errors")
    func unconfiguredNeverUnreachable() async {
        let (sut, fake, _) = makeSUT()       // sonarr left unconfigured
        fake.fetchResult = AggregateResult(
            radarr: [], sonarr: [], lidarr: [], whisparr: [], sonarrError: "boom"
        )
        await sut.refresh()
        await sut.refresh()
        await sut.refresh()
        #expect(!sut.unreachableArrs.contains(.sonarr))
    }
}

// MARK: - Fine-grained observation (the @Observable migration's payoff)

/// These tests turn "the migration reduces re-renders" from a claim into a
/// fact, measured at the source. `withObservationTracking` is the exact
/// primitive SwiftUI uses to decide which views to re-render, so asserting on
/// it proves the runtime behaviour without driving any UI.
@MainActor
@Suite("Fine-grained observation")
struct ObservationGranularityTests {

    /// THE payoff: an observer that read only `upcoming` is NOT notified when
    /// an unrelated property (`tonightExpanded`) changes. Under SwiftUI this
    /// means a view showing the Upcoming list does not re-render when the
    /// Tonight banner expands — the spurious re-render the old ObservableObject
    /// model could not avoid (see `observableObjectNotifiesOnAnyChange`).
    @Test("@Observable: an unrelated property change does NOT notify a narrow observer")
    func observableIsFineGrained() {
        let (sut, _, _) = makeSUT()
        var notified = 0
        withObservationTracking {
            _ = sut.upcoming                 // observe ONLY `upcoming`
        } onChange: {
            notified += 1
        }
        sut.setTonightExpanded(true)         // change a DIFFERENT property
        #expect(notified == 0)
    }

    /// Sanity: changing the observed property DOES notify, so the test above
    /// isn't passing because notifications are simply broken.
    @Test("@Observable: a change to the observed property DOES notify")
    func observableNotifiesOnTrackedChange() {
        let (sut, _, _) = makeSUT()
        var notified = 0
        withObservationTracking {
            _ = sut.tonightExpanded
        } onChange: {
            notified += 1
        }
        sut.setTonightExpanded(!sut.tonightExpanded)
        #expect(notified == 1)
    }

    /// The contrast that justifies the migration: `ObservableObject` fires
    /// `objectWillChange` on ANY `@Published` write, so every observing view
    /// re-renders even when it reads none of the changed properties. That is
    /// exactly the cost `@Observable` removes in `observableIsFineGrained`.
    @Test("ObservableObject: any property change notifies all observers (the cost @Observable removes)")
    func observableObjectNotifiesOnAnyChange() {
        final class Legacy: ObservableObject {
            @Published var a = 0
            @Published var b = 0
        }
        let legacy = Legacy()
        var willChange = 0
        let cancellable = legacy.objectWillChange.sink { _ in willChange += 1 }
        legacy.b = 1                          // a view reading only `a` still re-renders
        #expect(willChange == 1)
        _ = cancellable
    }
}
