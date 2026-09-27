import Foundation
import os

public struct LiveStreamID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let queue = LiveStreamID(rawValue: "queue")
    public static let progress = LiveStreamID(rawValue: "progress")
    public static let sessions = LiveStreamID(rawValue: "sessions")
}

public enum LiveScope: Sendable, Equatable { case all, ids(Set<String>) }
public enum LiveActivity: Sendable, Equatable { case foreground, background, paused }

public struct LivePolicy: Sendable, Equatable {
    public var foregroundInterval: Duration = .seconds(30)
    public var backgroundInterval: Duration = .seconds(120)
    public var pushSilence: Duration = .seconds(300)
    public var staleGrace: Duration = .seconds(60)
    public var checkpointDebounce: Duration = .seconds(5)
    public init() {}

    public static let queue = LivePolicy()
    public static let progress: LivePolicy = { var p = LivePolicy(); p.foregroundInterval = .seconds(2); p.backgroundInterval = .seconds(0); return p }()
    public static let sessions = LivePolicy()
}

public struct LiveValue<Element: Codable & Sendable>: Sendable {
    public let elements: [Element]
    /// Each instance's rows after the overlay; a failed instance keeps its last good slice.
    public let slices: [InstanceID: LiveSlice<Element>]
    /// The oldest slice's measurement.
    public let measuredAt: Date
    public let partial: Set<InstanceID>
    /// Why each instance in `partial` failed this cycle.
    public let failures: [InstanceID: any Error]
    public let isStale: Bool
    public let pending: [PendingEffect]
    public let isFromSnapshot: Bool
}

public struct LiveSlice<Element: Codable & Sendable>: Sendable {
    public let elements: [Element]
    public let measuredAt: Date
}

/// An element that can carry an optimistic status while the source catches up.
public protocol LivePatchable {
    func applying(_ change: PendingEffect.Change) -> Self?
}

private struct StoredLive<Element: Codable>: Codable { let elements: [Element]; let measuredAt: Date }

public actor LiveStream<Element: Codable & Sendable & Equatable & LivePatchable>: LiveStreamPushTarget {
    public typealias Fetch = @Sendable (InstanceID, LiveScope, RequestPipeline) async throws -> [Element]

    public let id: LiveStreamID
    private var instances: [InstanceID]
    private var policy: LivePolicy
    private let pipeline: RequestPipeline
    private let database: SQLiteDatabase?
    private let clock: any MediaClock
    private let telemetry: any TelemetrySink
    private let log: any LogSink
    private let elementID: @Sendable (Element) -> String
    private let fetch: Fetch
    private let isActive: @Sendable ([Element]) -> Bool

    private let lastValue = OSAllocatedUnfairLock<LiveValue<Element>?>(initialState: nil)
    private var subscribers: [UUID: AsyncStream<LiveValue<Element>>.Continuation] = [:]
    private var pump: Task<Void, Never>?
    private var activity: LiveActivity = .foreground
    private var scope: LiveScope = .all
    private var lastPush: [InstanceID: Date] = [:]
    private var pending: [PendingEffect] = []
    private var lastSeen: [String: (instance: InstanceID, element: Element)] = [:]
    private var slices: [InstanceID: LiveSlice<Element>] = [:]
    private var failures: [InstanceID: any Error] = [:]
    private var fromSnapshot = false
    private var refreshRequested = false
    private var wakeup: CheckedContinuation<Void, Never>?
    private var lastCheckpoint: Date?
    private var running: (seq: Int, task: Task<Void, Never>)?
    private var queued: Task<Void, Never>?
    private var cycleSeq = 0

    public init(id: LiveStreamID, instances: [InstanceID], policy: LivePolicy, pipeline: RequestPipeline, database: SQLiteDatabase?,
                clock: any MediaClock, telemetry: any TelemetrySink, log: any LogSink,
                elementID: @escaping @Sendable (Element) -> String, fetch: @escaping Fetch,
                isActive: @escaping @Sendable ([Element]) -> Bool = { _ in false }) {
        self.id = id; self.instances = instances; self.policy = policy; self.pipeline = pipeline; self.database = database
        self.clock = clock; self.telemetry = telemetry; self.log = log; self.elementID = elementID; self.fetch = fetch; self.isActive = isActive
    }

    public func values() -> AsyncStream<LiveValue<Element>> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LiveValue<Element>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        if let current = lastValue.withLock({ $0 }) { continuation.yield(current) }
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers.removeValue(forKey: id) }

    /// Lock-guarded; non-nil after `start()` when a snapshot exists.
    public nonisolated func last() -> LiveValue<Element>? { lastValue.withLock { $0 } }

    public func start() async {
        guard pump == nil else { return }
        await loadSnapshot()
        pump = Task { await self.run() }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
    }

    /// Returns once a fetch that started after this call has published.
    public func refreshNow(priority: RequestPriority = .interactive) async {
        await cycle()
    }

    public func setActivity(_ value: LiveActivity) {
        guard activity != value else { return }
        activity = value
        wake()
    }

    public func setScope(_ value: LiveScope) {
        guard scope != value else { return }
        scope = value
        refreshRequested = true
        wake()
    }

    public func setInstances(_ value: [InstanceID]) {
        instances = value
        slices = slices.filter { value.contains($0.key) }
        failures = failures.filter { value.contains($0.key) }
        refreshRequested = true
        wake()
    }

    public func setPolicy(_ value: LivePolicy) {
        guard policy != value else { return }
        policy = value
        wake()
    }

    public func notePush(_ instance: InstanceID, at date: Date) async {
        guard instances.contains(instance) else { return }
        lastPush[instance] = date
        refreshRequested = true
        wake()
    }

    /// Optimistic overlay; the store is untouched.
    public func apply(_ effect: PendingEffect) {
        pending.removeAll { $0.elementID == effect.elementID && $0.instance == effect.instance }
        pending.append(effect)
        guard lastValue.withLock({ $0 }) != nil else { return }
        publish()
    }

    public func clear(elementID: String) { pending.removeAll { $0.elementID == elementID } }

    private func wake() {
        wakeup?.resume()
        wakeup = nil
    }

    // MARK: - Pump

    private func run() async {
        while !Task.isCancelled {
            if activity == .paused && !refreshRequested {
                await waitForWakeup()
                continue
            }
            if refreshRequested || !canSkipTick() {
                refreshRequested = false
                await cycle()
            }
            // A push or scope change that landed mid-cycle is not left for the next interval.
            if refreshRequested { continue }
            let interval = activity == .foreground ? policy.foregroundInterval : policy.backgroundInterval
            if interval == .zero {
                await waitForWakeup()
            } else {
                await sleepOrWake(interval)
            }
        }
    }

    private func waitForWakeup() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in wakeup = c }
    }

    private func sleepOrWake(_ interval: Duration) async {
        let sleeper = Task { [clock] in try? await clock.sleep(for: interval) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                wakeup = c
                Task { _ = await sleeper.value; self.wakeFromSleep() }
            }
        } onCancel: { sleeper.cancel() }
    }

    private func wakeFromSleep() { wake() }

    /// Today's `canSkipForegroundTick`: every instance covered by push, nothing active, no pending effect.
    private func canSkipTick() -> Bool {
        let now = clock.now
        let covered = instances.allSatisfy { lastPush[$0].map { now.timeIntervalSince($0) < policy.pushSilence.seconds } ?? false }
        let elements = lastValue.withLock { $0?.elements } ?? []
        return covered && !isActive(elements) && pending.isEmpty && !instances.isEmpty
    }

    /// One fetch at a time; a caller arriving mid-fetch shares the next one, so it never reads a value older than its call.
    private func cycle() async {
        if let queued {
            await queued.value
            return
        }
        if let running {
            let prior = running.task
            let task = Task { await prior.value; await self.startCycle(fromQueue: true) }
            queued = task
            await task.value
            return
        }
        await startCycle(fromQueue: false)
    }

    private func startCycle(fromQueue: Bool) async {
        if fromQueue { queued = nil }
        cycleSeq += 1
        let seq = cycleSeq
        let task = Task { await self.fetchAndPublish() }
        running = (seq, task)
        await task.value
        if running?.seq == seq { running = nil }
    }

    private func fetchAndPublish() async {
        let instances = self.instances
        let scope = self.scope
        let pipeline = self.pipeline
        let fetch = self.fetch
        // nil rows with nil error: cancelled, which leaves that instance's slice as it was.
        var outcomes: [(InstanceID, [Element]?, (any Error)?)] = []
        await withTaskGroup(of: (InstanceID, [Element]?, (any Error)?).self) { group in
            for instance in instances {
                group.addTask {
                    do { return (instance, try await fetch(instance, scope, pipeline), nil) }
                    catch is CancellationError { return (instance, nil, nil) }
                    catch { return Task.isCancelled ? (instance, nil, nil) : (instance, nil, error) }
                }
            }
            for await outcome in group { outcomes.append(outcome) }
        }
        let now = clock.now
        var changed = instances.isEmpty
        var fresh: [InstanceID: [Element]] = [:]
        for (instance, rows, error) in outcomes {
            if let rows {
                slices[instance] = LiveSlice(elements: rows, measuredAt: now)
                failures[instance] = nil
                fresh[instance] = rows
                changed = true
            } else if let error {
                failures[instance] = error
                changed = true
            }
        }
        guard changed else { return }
        fromSnapshot = false
        for (instance, rows) in fresh {
            for e in rows { lastSeen[Self.key(instance, elementID(e))] = (instance, e) }
        }
        publish()
        if !fresh.isEmpty { await checkpoint(fresh, at: now) }
    }

    private static func key(_ instance: InstanceID, _ element: String) -> String { "\(instance)|\(element)" }

    private func publish() {
        let now = clock.now
        pending.removeAll { $0.expiresAt <= now }
        var overlaid: [InstanceID: [Element]] = [:]
        for instance in instances { overlaid[instance] = slices[instance]?.elements ?? [] }
        var live: [PendingEffect] = []
        for effect in pending {
            let targets = effect.instance.map { [$0] } ?? instances
            var matched = false
            for instance in targets {
                guard var rows = overlaid[instance] else { continue }
                let index = rows.firstIndex { elementID($0) == effect.elementID }
                switch effect.change {
                case let .status(status):
                    // Dropped once the source reports the same status, or the row is gone.
                    guard let index, let patched = rows[index].applying(.status(status)), patched != rows[index] else { continue }
                    rows[index] = patched
                case .removed:
                    guard let index else { continue }
                    rows.remove(at: index)
                case .keepAlive:
                    // Ghosts the last seen row while the source omits it; only expiry ends it.
                    if index == nil, let ghost = lastSeen[Self.key(instance, effect.elementID)] { rows.append(ghost.element) }
                    else if index == nil { continue }
                }
                overlaid[instance] = rows
                matched = true
            }
            if matched || effect.change == .keepAlive { live.append(effect) }
        }
        pending = live
        let partial = Set(failures.keys)
        var outSlices: [InstanceID: LiveSlice<Element>] = [:]
        for instance in instances {
            guard let slice = slices[instance] else { continue }
            outSlices[instance] = LiveSlice(elements: overlaid[instance] ?? [], measuredAt: slice.measuredAt)
        }
        let elements = instances.flatMap { outSlices[$0]?.elements ?? [] }
        let measuredAt = outSlices.values.map(\.measuredAt).min() ?? now
        let isStale = partial.contains { instance in
            slices[instance].map { now.timeIntervalSince($0.measuredAt) >= policy.staleGrace.seconds } ?? false
        }
        let value = LiveValue(elements: elements, slices: outSlices, measuredAt: measuredAt, partial: partial, failures: failures,
                              isStale: isStale, pending: live, isFromSnapshot: fromSnapshot)
        lastValue.withLock { $0 = value }
        for c in subscribers.values { c.yield(value) }
    }

    private func loadSnapshot() async {
        guard let database else { return }
        var found = false
        for instance in instances {
            guard let (data, at) = try? await database.lastKnown(instance: instance, stream: id.rawValue),
                  let stored = try? WireCodec.decoder.decode(StoredLive<Element>.self, from: data) else { continue }
            slices[instance] = LiveSlice(elements: stored.elements, measuredAt: at)
            found = true
        }
        guard found else { return }
        fromSnapshot = true
        publish()
    }

    private func checkpoint(_ fresh: [InstanceID: [Element]], at date: Date) async {
        guard let database else { return }
        if let last = lastCheckpoint, date.timeIntervalSince(last) < policy.checkpointDebounce.seconds { return }
        lastCheckpoint = date
        for (instance, rows) in fresh {
            guard let data = try? WireCodec.encoder.encode(StoredLive(elements: rows, measuredAt: date)) else { continue }
            try? await database.putLastKnown(instance: instance, stream: id.rawValue, payload: data, at: date)
        }
    }
}
