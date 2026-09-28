import Foundation
import os

public struct LiveStreamID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let queue = LiveStreamID(rawValue: "queue")
    public static let progress = LiveStreamID(rawValue: "progress")
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
}

public struct LiveValue<Element: Codable & Sendable>: Sendable {
    public let elements: [Element]
    /// Each instance's rows after the overlay; a failed instance keeps its last good slice.
    public let slices: [InstanceID: LiveSlice<Element>]
    public let measuredAt: Date
    public let partial: Set<InstanceID>
    /// Why each instance in `partial` failed this cycle.
    public let failures: [InstanceID: any Error]
    public let isStale: Bool
    public let pending: [PendingEffect]
    public let isFromSnapshot: Bool
    /// Bumped by every fetch; an overlay change republishes the same revision. 0 is the snapshot.
    public let revision: UInt64
    /// Bumped by every applied effect, so a republish of the same revision still reads as new.
    public let overlay: UInt64
}

public struct LiveSlice<Element: Codable & Sendable>: Sendable {
    public let elements: [Element]
    public let measuredAt: Date
}

/// An element that can carry an optimistic status while the source catches up.
public protocol LivePatchable {
    func applying(_ change: PendingEffect.Change) -> Self?
    /// Other ids an effect may name this element by (a queue row by its download id).
    var liveAliases: [String] { get }
    /// Whether this element is what `gone` turned into, so `gone`'s ghost can retire.
    func succeeds(_ gone: Self) -> Bool
}

public extension LivePatchable {
    var liveAliases: [String] { [] }
    func succeeds(_ gone: Self) -> Bool { false }
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
    private var pending: [(effect: PendingEffect, expiresAt: Date)] = []
    private var lastSeen: [String: (instance: InstanceID, element: Element, position: Int)] = [:]
    /// The element ids present when each effect was applied: a successor has to be new.
    private var presentAtApply: [String: Set<String>] = [:]
    private var overlay: UInt64 = 0
    private var slices: [InstanceID: LiveSlice<Element>] = [:]
    private var failures: [InstanceID: any Error] = [:]
    private var fromSnapshot = false
    private var revision: UInt64 = 0
    /// When the last fetch finished, whoever asked for it; a tick inside the interval after it has nothing to add.
    private var lastFetchAt: Date?
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
        wake()
    }

    /// Returns once a fetch that started after this call has published.
    public func refreshNow() async {
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

    public func setPolicy(_ value: LivePolicy) {
        guard policy != value else { return }
        policy = value
        wake()
    }

    public func noteAlive(_ instance: InstanceID, at date: Date) async {
        guard instances.contains(instance) else { return }
        lastPush[instance] = max(lastPush[instance] ?? date, date)
    }

    public func notePush(_ instance: InstanceID, at date: Date) async {
        guard instances.contains(instance) else { return }
        lastPush[instance] = date
        refreshRequested = true
        wake()
    }

    /// Optimistic overlay; the store is untouched. `.status` patches (or ghosts) the row until the source
    /// agrees, expiry or a successor; `.removed` hides it until expiry.
    public func apply(_ effect: PendingEffect) {
        pending.removeAll { $0.effect.elementID == effect.elementID && $0.effect.instance == effect.instance }
        pending.append((effect, clock.now.addingTimeInterval(effect.lifetime.seconds)))
        let present = (effect.instance.map { [$0] } ?? instances).flatMap { slices[$0]?.elements ?? [] }.map(elementID)
        presentAtApply[Self.effectKey(effect)] = Set(present)
        overlay += 1
        wake()
        guard lastValue.withLock({ $0 }) != nil else { return }
        publish()
    }

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
            // Someone is already fetching (a refreshNow at launch or panel open): that fetch is this tick.
            if let running {
                await running.task.value
                continue
            }
            let interval = activity == .foreground ? policy.foregroundInterval : policy.backgroundInterval
            let age = lastFetchAt.map { clock.now.timeIntervalSince($0) }
            let fresh = age.map { $0 < interval.seconds } ?? false
            // In the background a push may bring the next fetch forward but not add one inside the interval:
            // nothing is on screen, and the interval is the latency chosen for the badge and notifications.
            let held = refreshRequested && fresh && activity != .foreground && interval != .zero
            if (refreshRequested && !held) || (!refreshRequested && !fresh && !canSkipTick()) {
                refreshRequested = false
                await cycle()
            }
            // A push or scope change that landed mid-cycle is not left for the next interval.
            if refreshRequested && !held { continue }
            if interval == .zero {
                await waitForWakeup()
            } else if fresh, let age {
                await sleepOrWake(.seconds(max(interval.seconds - age, 0.001)))
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

    /// Every instance covered by push and no pending effect. On screen an active element also keeps the tick,
    /// since its numbers move without an event; in the background nothing is drawn, so coverage alone decides.
    private func canSkipTick() -> Bool {
        let now = clock.now
        let covered = instances.allSatisfy { lastPush[$0].map { now.timeIntervalSince($0) < policy.pushSilence.seconds } ?? false }
        let elements = lastValue.withLock { $0?.elements } ?? []
        let activeMatters = activity == .foreground && isActive(elements)
        return covered && !activeMatters && pending.isEmpty && !instances.isEmpty
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
        lastFetchAt = now
        var changed = instances.isEmpty
        var fresh: [InstanceID: [Element]] = [:]
        // An instance removed while the fetch ran keeps no slice and no failure.
        for (instance, rows, error) in outcomes where self.instances.contains(instance) {
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
        revision += 1
        for (instance, rows) in fresh {
            for (position, e) in rows.enumerated() { lastSeen[Self.key(instance, elementID(e))] = (instance, e, position) }
        }
        publish()
        if !fresh.isEmpty { await checkpoint(fresh, at: now) }
    }

    private static func key(_ instance: InstanceID, _ element: String) -> String { "\(instance)|\(element)" }
    private static func effectKey(_ effect: PendingEffect) -> String { "\(effect.instance.map { "\($0)" } ?? "*")|\(effect.elementID)" }

    private func matches(_ element: Element, _ id: String) -> Bool { elementID(element) == id || element.liveAliases.contains(id) }

    private func lastSeenRow(_ instance: InstanceID, _ id: String) -> (element: Element, position: Int)? {
        if let hit = lastSeen[Self.key(instance, id)] { return (hit.element, hit.position) }
        return lastSeen.values.first { $0.instance == instance && $0.element.liveAliases.contains(id) }.map { ($0.element, $0.position) }
    }

    private func publish() {
        let now = clock.now
        pending.removeAll { $0.expiresAt <= now }
        var overlaid: [InstanceID: [Element]] = [:]
        for instance in instances { overlaid[instance] = slices[instance]?.elements ?? [] }
        var live: [(effect: PendingEffect, expiresAt: Date)] = []
        for entry in pending {
            let effect = entry.effect
            let targets = effect.instance.map { [$0] } ?? instances
            var matched = false
            for instance in targets {
                guard var rows = overlaid[instance] else { continue }
                let index = rows.firstIndex { matches($0, effect.elementID) }
                switch effect.change {
                case let .status(status):
                    if let index {
                        // Dropped once the source reports the same status.
                        guard let patched = rows[index].applying(.status(status)), patched != rows[index] else { continue }
                        rows[index] = patched
                    } else {
                        guard let seen = lastSeenRow(instance, effect.elementID), let ghost = seen.element.applying(.status(status)) else { continue }
                        let before = presentAtApply[Self.effectKey(effect)] ?? []
                        if rows.contains(where: { $0.succeeds(seen.element) && !before.contains(elementID($0)) }) { continue }
                        rows.insert(ghost, at: min(seen.position, rows.count))
                    }
                case .removed:
                    if let index { rows.remove(at: index) }
                case .keepAlive:
                    // Ghosts the last seen row while the source omits it; only expiry ends it.
                    if index == nil, let ghost = lastSeenRow(instance, effect.elementID) { rows.insert(ghost.element, at: min(ghost.position, rows.count)) }
                    else if index == nil { continue }
                }
                overlaid[instance] = rows
                matched = true
            }
            if matched || effect.change == .keepAlive || effect.change == .removed { live.append(entry) }
        }
        pending = live
        presentAtApply = presentAtApply.filter { key, _ in live.contains { Self.effectKey($0.effect) == key } }
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
                              isStale: isStale, pending: live.map(\.effect), isFromSnapshot: fromSnapshot, revision: revision,
                              overlay: overlay)
        lastValue.withLock { $0 = value }
        for c in subscribers.values { c.yield(value) }
    }

    private func loadSnapshot() async {
        // The checkpoint is older than anything fetched in this process.
        guard let database, revision == 0, slices.isEmpty else { return }
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
