import Foundation
import os

public protocol LiveStreamPushTarget: Sendable {
    func notePush(_ instance: InstanceID, at: Date) async
}

/// Coalesces pushes per instance in a burst window, then invalidates the store and nudges the live streams.
public actor EventHub {
    public struct Cadence: Sendable, Equatable {
        public var burstWindow: Duration = .milliseconds(250)
        public var foregroundFloor: Duration = .seconds(1)
        public var backgroundFloor: Duration = .seconds(30)
        public init() {}
    }

    private let store: ResourceStore
    private let tagMap: EventTagMap
    private let clock: any MediaClock
    private let telemetry: any TelemetrySink
    private let log: any LogSink
    private let cadence: Cadence
    private var sources: [InstanceID: (source: SignalRSource, pump: Task<Void, Never>)] = [:]
    private var streams: [any LiveStreamPushTarget] = []
    private var lastCounts: [InstanceID: QueueCounts] = [:]
    private var pendingTags: [InstanceID: Set<InvalidationTag>] = [:]
    private var flushTasks: [InstanceID: Task<Void, Never>] = [:]
    private var lastFlush: [InstanceID: Date] = [:]
    private var subscribers: [UUID: AsyncStream<DataEvent>.Continuation] = [:]
    private let lastEvent = OSAllocatedUnfairLock<[InstanceID: Date]>(initialState: [:])
    private var foreground = true

    public init(store: ResourceStore, tagMap: EventTagMap = EventTagMap(), cadence: Cadence = Cadence(), clock: any MediaClock,
                telemetry: any TelemetrySink, log: any LogSink) {
        self.store = store; self.tagMap = tagMap; self.cadence = cadence; self.clock = clock; self.telemetry = telemetry; self.log = log
    }

    public func attach(_ source: SignalRSource, for instance: InstanceID) async {
        await detach(instance)
        let stream = await source.events()
        let pump = Task { for await event in stream { await self.ingest(event) } }
        sources[instance] = (source, pump)
        await source.start()
    }

    public func detach(_ instance: InstanceID) async {
        guard let entry = sources.removeValue(forKey: instance) else { return }
        entry.pump.cancel()
        await entry.source.stop()
    }

    public func register(_ stream: any LiveStreamPushTarget) { streams.append(stream) }

    public func setForeground(_ value: Bool) { foreground = value }

    /// Force a reconnect on every source and emit `.woke`; the governor and streams do the rest.
    public func wakeAll() async {
        for (_, entry) in sources { await entry.source.forceReconnect() }
        let event = DataEvent.woke(clock.now)
        for c in subscribers.values { c.yield(event) }
    }

    public func events() -> AsyncStream<DataEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DataEvent>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers.removeValue(forKey: id) }

    public nonisolated func lastEventAt(_ instance: InstanceID) -> Date? { lastEvent.withLock { $0[instance] } }

    /// Entry for events from any source, including tests.
    public func ingest(_ event: DataEvent) async {
        for c in subscribers.values { c.yield(event) }
        guard let instance = event.instance else { return }
        let now = clock.now
        lastEvent.withLock { $0[instance] = now }
        let tags = tagMap.tags(for: event, lastCounts: lastCounts[instance])
        if case let .queueStatus(_, counts) = event { lastCounts[instance] = counts }
        guard !tags.isEmpty else { return }
        pendingTags[instance, default: []].formUnion(tags)
        guard flushTasks[instance] == nil else { return }
        let floor = foreground ? cadence.foregroundFloor : cadence.backgroundFloor
        let sinceLast = lastFlush[instance].map { now.timeIntervalSince($0) } ?? .infinity
        let wait = max(cadence.burstWindow.seconds, floor.seconds - sinceLast)
        flushTasks[instance] = Task { [clock] in
            try? await clock.sleep(for: .seconds(wait))
            await self.flush(instance)
        }
    }

    private func flush(_ instance: InstanceID) async {
        flushTasks[instance] = nil
        guard let tags = pendingTags.removeValue(forKey: instance), !tags.isEmpty else { return }
        lastFlush[instance] = clock.now
        await store.invalidate(tags, reason: .event)
        for stream in streams { await stream.notePush(instance, at: clock.now) }
    }
}
