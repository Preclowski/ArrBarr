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
    public let measuredAt: Date
    public let partial: Set<InstanceID>
    public let isStale: Bool
    public let pending: [PendingEffect]
    public let isFromSnapshot: Bool
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
    private let policy: LivePolicy
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
    private var lastSeen: [String: Element] = [:]
    private var lastGood: (elements: [Element], at: Date)?
    private var refreshRequested = false
    private var wakeup: CheckedContinuation<Void, Never>?
    private var lastCheckpoint: Date?
    private var cycleInFlight = false

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

    public func refreshNow(priority: RequestPriority = .interactive) async {
        refreshRequested = true
        wakeup?.resume()
        wakeup = nil
        if pump == nil { await cycle() }
    }

    public func setActivity(_ value: LiveActivity) {
        guard activity != value else { return }
        activity = value
        wakeup?.resume()
        wakeup = nil
    }

    public func setScope(_ value: LiveScope) {
        guard scope != value else { return }
        scope = value
        refreshRequested = true
        wakeup?.resume()
        wakeup = nil
    }

    public func setInstances(_ value: [InstanceID]) {
        instances = value
        refreshRequested = true
        wakeup?.resume()
        wakeup = nil
    }

    public func notePush(_ instance: InstanceID, at date: Date) async {
        lastPush[instance] = date
        refreshRequested = true
        wakeup?.resume()
        wakeup = nil
    }

    /// Optimistic overlay; the store is untouched.
    public func apply(_ effect: PendingEffect) {
        pending.removeAll { $0.elementID == effect.elementID }
        pending.append(effect)
        if let current = lastValue.withLock({ $0 }) { publish(current.elements, measuredAt: current.measuredAt, partial: current.partial, isStale: current.isStale, fromSnapshot: current.isFromSnapshot) }
    }

    public func clear(elementID: String) { pending.removeAll { $0.elementID == elementID } }

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
            let interval = activity == .foreground ? policy.foregroundInterval : policy.backgroundInterval
            if interval == .zero, activity != .foreground {
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

    private func wakeFromSleep() {
        wakeup?.resume()
        wakeup = nil
    }

    /// Today's `canSkipForegroundTick`: every instance covered by push, nothing active, no pending effect.
    private func canSkipTick() -> Bool {
        let now = clock.now
        let covered = instances.allSatisfy { lastPush[$0].map { now.timeIntervalSince($0) < policy.pushSilence.seconds } ?? false }
        let elements = lastValue.withLock { $0?.elements } ?? []
        return covered && !isActive(elements) && pending.isEmpty && !instances.isEmpty
    }

    private func cycle() async {
        guard !cycleInFlight else { refreshRequested = true; return }
        cycleInFlight = true
        defer { cycleInFlight = false }
        let scope = self.scope
        let pipeline = self.pipeline
        let fetch = self.fetch
        var elements: [Element] = []
        var failed = Set<InstanceID>()
        await withTaskGroup(of: (InstanceID, [Element]?).self) { group in
            for instance in instances {
                group.addTask { (instance, try? await fetch(instance, scope, pipeline)) }
            }
            for await (instance, result) in group {
                if let result { elements.append(contentsOf: result) } else { failed.insert(instance) }
            }
        }
        let now = clock.now
        if failed.count == instances.count, !instances.isEmpty {
            let previous = lastGood ?? (lastValue.withLock { $0 }).map { ($0.elements, $0.measuredAt) }
            guard let previous else {
                publish([], measuredAt: now, partial: failed, isStale: false, fromSnapshot: false)
                return
            }
            let withinGrace = now.timeIntervalSince(previous.at) < policy.staleGrace.seconds
            publish(previous.elements, measuredAt: previous.at, partial: failed, isStale: !withinGrace, fromSnapshot: false)
            return
        }
        lastGood = (elements, now)
        for e in elements { lastSeen[elementID(e)] = e }
        publish(elements, measuredAt: now, partial: failed, isStale: false, fromSnapshot: false)
        await checkpoint(elements, at: now)
    }

    private func publish(_ raw: [Element], measuredAt: Date, partial: Set<InstanceID>, isStale: Bool, fromSnapshot: Bool) {
        let now = clock.now
        pending.removeAll { $0.expiresAt <= now }
        var elements = raw
        var live: [PendingEffect] = []
        for effect in pending {
            let index = elements.firstIndex { elementID($0) == effect.elementID }
            switch effect.change {
            case let .status(status):
                // Dropped once the source reports the same status, or the row is gone.
                guard let index, let patched = elements[index].applying(.status(status)), patched != elements[index] else { continue }
                elements[index] = patched
                live.append(effect)
            case .removed:
                guard let index else { continue }
                elements.remove(at: index)
                live.append(effect)
            case .keepAlive:
                // Ghosts the last seen row while the source omits it; only expiry ends it.
                if index == nil, let ghost = lastSeen[effect.elementID] { elements.append(ghost) }
                live.append(effect)
            }
        }
        pending = live
        let value = LiveValue(elements: elements, measuredAt: measuredAt, partial: partial, isStale: isStale, pending: live, isFromSnapshot: fromSnapshot)
        lastValue.withLock { $0 = value }
        for c in subscribers.values { c.yield(value) }
    }

    private func loadSnapshot() async {
        guard let database, let first = instances.first else { return }
        var elements: [Element] = []
        var captured: Date?
        for instance in instances {
            guard let (data, at) = try? await database.lastKnown(instance: instance, stream: id.rawValue),
                  let stored = try? WireCodec.decoder.decode(StoredLive<Element>.self, from: data) else { continue }
            elements.append(contentsOf: stored.elements)
            captured = min(captured ?? at, at)
        }
        _ = first
        guard let captured else { return }
        publish(elements, measuredAt: captured, partial: [], isStale: false, fromSnapshot: true)
    }

    private func checkpoint(_ elements: [Element], at date: Date) async {
        guard let database else { return }
        if let last = lastCheckpoint, date.timeIntervalSince(last) < policy.checkpointDebounce.seconds { return }
        lastCheckpoint = date
        for instance in instances {
            let mine = elements.filter { elementID($0).hasPrefix(instance.description) || instances.count == 1 }
            guard let data = try? WireCodec.encoder.encode(StoredLive(elements: mine, measuredAt: date)) else { continue }
            try? await database.putLastKnown(instance: instance, stream: id.rawValue, payload: data, at: date)
        }
    }
}
