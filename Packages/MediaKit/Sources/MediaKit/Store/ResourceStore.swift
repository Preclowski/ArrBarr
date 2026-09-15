import Foundation
import os

public actor ResourceStore {
    private struct InFlight {
        let task: Task<CommittedRow, any Error>
        var waiters: Set<UInt64> = []
    }

    struct CommittedRow: Sendable {
        let payload: Data
        let fetchedAt: Date
        let staleAt: Date
        let tags: Set<InvalidationTag>
    }

    public nonisolated let revision = StoreRevision()
    public nonisolated let subject = MessageSubject()
    let database: SQLiteDatabase?
    let pipeline: RequestPipeline
    let identity: IdentityStore?
    let clock: any MediaClock
    let telemetry: any TelemetrySink
    let log: any LogSink
    let center: NotificationCenter
    private var memory: MemoryTier
    /// Keyed by key and fingerprint: a request for a reconfigured instance never joins the old instance's fetch.
    private var inFlight: [String: InFlight] = [:]
    private var nextWaiter: UInt64 = 0
    private var revalidations: [ResourceKey: Task<Void, Never>] = [:]
    private var commandTrackers: [Int: Task<Void, Never>] = [:]
    private let sweepEvery: Duration = .seconds(6 * 3600)
    private var lastSweep: Date?
    var probe: CapabilityProbe?
    var capabilities = CapabilityIndex()
    /// Forces every read to this policy; a test process sets `.mustRevalidate` so stubs answer each request.
    public var policyOverride: ReadPolicy?

    public init(database: SQLiteDatabase?, pipeline: RequestPipeline, identity: IdentityStore?, clock: any MediaClock,
                telemetry: any TelemetrySink, log: any LogSink, center: NotificationCenter = .default, memoryBudget: Int = 8 << 20) {
        self.database = database; self.pipeline = pipeline; self.identity = identity; self.clock = clock
        self.telemetry = telemetry; self.log = log; self.center = center
        memory = MemoryTier(budget: memoryBudget)
    }

    public func setPolicyOverride(_ policy: ReadPolicy?) { policyOverride = policy }

    func attach(probe: CapabilityProbe, capabilities: CapabilityIndex) {
        self.probe = probe
        self.capabilities = capabilities
    }

    public func start() async {}

    // MARK: - Reads

    public func read<V>(_ resource: Resource<V>, policy requested: ReadPolicy = .cacheFirst, maxAge: Duration? = nil,
                        priority: RequestPriority = .interactive) async throws -> Fetched<V> {
        let policy = policyOverride ?? requested
        let now = clock.now
        let fingerprint = pipeline.registry.fingerprint(resource.key.instance)
        let cached = await lookup(resource.key, fingerprint: fingerprint, now: now)
        let ttl = min(resource.effectiveTTL.seconds, maxAge?.seconds ?? .infinity)
        let fresh = cached.map { now < min($0.entry.fetchedAt.addingTimeInterval(ttl), $0.entry.staleAt) } ?? false

        switch policy {
        case .cacheOnly:
            guard let cached else { throw MediaKitError.notConfigured(resource.key.instance) }
            telemetry.record(.cacheHit(resource.key, cached.origin))
            return try decode(resource, cached.entry, origin: cached.origin, isStale: !fresh, degraded: nil)
        case .cacheFirst where fresh, .staleWhileRevalidate where fresh:
            telemetry.record(.cacheHit(resource.key, cached!.origin))
            return try decode(resource, cached!.entry, origin: cached!.origin, isStale: false, degraded: nil)
        case .staleWhileRevalidate:
            if let cached {
                telemetry.record(.cacheHit(resource.key, cached.origin))
                scheduleRevalidation(resource)
                return try decode(resource, cached.entry, origin: cached.origin, isStale: true, degraded: nil)
            }
        default:
            break
        }
        telemetry.record(.cacheMiss(resource.key))
        do {
            let row = try await fetch(resource, fingerprint: fingerprint, priority: priority)
            return Fetched(value: try Self.stored(V.self, row.payload, operation: resource.key.operation), origin: .network,
                           fetchedAt: row.fetchedAt, isStale: false, tags: row.tags, degraded: nil)
        } catch let error as MediaKitError {
            if policy != .mustRevalidate, let cached {
                telemetry.record(.staleServed(resource.key, error))
                return try decode(resource, cached.entry, origin: cached.origin, isStale: true, degraded: error)
            }
            throw error
        }
    }

    /// cached → revalidated → one element per matching invalidation or commit.
    public nonisolated func observe<V>(_ resource: Resource<V>, maxAge: Duration? = nil,
                                       priority: RequestPriority = .interactive) -> AsyncStream<Fetched<V>> {
        AsyncStream { continuation in
            let task = Task {
                var last: (fetchedAt: Date, isStale: Bool)?
                let tags = resource.tags
                let observations = Observations { [revision] in tags.reduce(UInt64(0)) { $0 &+ revision.tick(for: $1) } }
                if let first = try? await self.read(resource, policy: .staleWhileRevalidate, maxAge: maxAge, priority: priority) {
                    last = (first.fetchedAt, first.isStale)
                    continuation.yield(first)
                }
                for await _ in observations {
                    guard !Task.isCancelled else { break }
                    guard let next = try? await self.read(resource, policy: .cacheFirst, maxAge: maxAge, priority: priority) else { continue }
                    // A frozen clock (tests) keeps fetchedAt equal across fetches; origin tells a refetch apart.
                    if next.origin == .network || next.fetchedAt != last?.fetchedAt || next.isStale != last?.isStale {
                        last = (next.fetchedAt, next.isStale)
                        continuation.yield(next)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Every key maps to the rows the source returned for it (empty when none), or the failure of its chunk.
    public func batch<K, V>(_ batch: BatchResource<K, V>, keys: [K], policy: ReadPolicy = .cacheFirst, maxAge: Duration? = nil,
                            priority: RequestPriority = .interactive) async -> [K: Result<[V], MediaKitError>] where K: Comparable {
        var out: [K: Result<[V], MediaKitError>] = [:]
        let unique = Array(Set(keys)).sorted()
        switch batch.strategy {
        case let .chunked(max, make, identify):
            await withTaskGroup(of: ([K], Result<[V], MediaKitError>).self) { group in
                for chunk in stride(from: 0, to: unique.count, by: max).map({ Array(unique[$0..<min($0 + max, unique.count)]) }) {
                    group.addTask {
                        do { return (chunk, .success(try await self.read(make(chunk), policy: policy, maxAge: maxAge, priority: priority).value)) }
                        catch let error as MediaKitError { return (chunk, .failure(error)) }
                        catch { return (chunk, .failure(.unreachable(Host(URL(string: "mediakit://cancelled")!), .other))) }
                    }
                }
                for await (chunk, result) in group {
                    switch result {
                    case let .success(values):
                        for key in chunk { out[key] = .success([]) }
                        for value in values { if let key = identify(value), case var .success(rows)? = out[key] { rows.append(value); out[key] = .success(rows) } }
                    case let .failure(error):
                        for key in chunk { out[key] = .failure(error) }
                    }
                }
            }
        case let .perKey(make):
            await withTaskGroup(of: (K, Result<[V], MediaKitError>).self) { group in
                for key in unique {
                    group.addTask {
                        do { return (key, .success(try await self.read(make(key), policy: policy, maxAge: maxAge, priority: priority).value)) }
                        catch let error as MediaKitError { return (key, .failure(error)) }
                        catch { return (key, .failure(.unreachable(Host(URL(string: "mediakit://cancelled")!), .other))) }
                    }
                }
                for await (key, result) in group { out[key] = result }
            }
        }
        return out
    }

    // MARK: - Commands

    public func run(_ command: Command, priority: RequestPriority = .interactive) async throws -> CommandReceipt {
        let context = CommandContext(pipeline: pipeline, probe: probe, capabilities: capabilities, clock: clock)
        let receipt = try await command.run(context)
        await invalidate(command.invalidates, reason: .command)
        if case let .arrCommand(timeout)? = command.tracking, let id = receipt.trackingID {
            track(commandID: id, instance: command.instance, invalidates: command.invalidates, timeout: timeout)
        }
        return receipt
    }

    private func track(commandID: Int, instance: InstanceID, invalidates: Set<InvalidationTag>, timeout: Duration) {
        commandTrackers[commandID]?.cancel()
        commandTrackers[commandID] = Task { [clock, pipeline] in
            let deadline = clock.now.addingTimeInterval(timeout.seconds)
            let api = instance.kind == .lidarr ? "/api/v1" : "/api/v3"
            while clock.now < deadline, !Task.isCancelled {
                try? await clock.sleep(for: .seconds(3))
                let plan = RequestPlan(instance: instance, operation: "commandStatus", pathTemplate: "\(api)/command/{id}",
                                       pathValues: ["id": String(commandID)], auth: .header("X-Api-Key"), priority: .background)
                guard let response = try? await pipeline.send(plan),
                      let status = (try? JSONDecoder().decode(JSONValue.self, from: response.body))?["status"]?.stringValue else { continue }
                if status == "completed" || status == "failed" || status == "aborted" || status == "cancelled" {
                    await self.invalidate(invalidates.union([.collection(.commands, instance)]), reason: .command)
                    break
                }
            }
            self.forgetTracker(commandID)
        }
    }

    private func forgetTracker(_ id: Int) { commandTrackers.removeValue(forKey: id) }

    // MARK: - Invalidation and maintenance

    public func invalidate(_ tags: Set<InvalidationTag>, reason: InvalidationReason) async {
        guard !tags.isEmpty else { return }
        let now = clock.now
        memory.markStale(tags: tags, at: now)
        if let database { _ = try? await database.markStale(tags: tags, at: now) }
        telemetry.record(.invalidated(tags, reason))
        if reason != .sweep { log.log(.debug, category: "Store", "invalidate \(tags.count) tags (\(reason.rawValue))") }
        revision.bump(tags)
        center.post(Invalidated(tags: tags, reason: reason), subject: subject)
    }

    public func invalidate(instance: InstanceID, reason: InvalidationReason) async {
        let now = clock.now
        memory.markStale(instance: instance, at: now)
        if let database { _ = try? await database.markStale(instance: instance, at: now) }
        let tag = InvalidationTag.instance(instance)
        telemetry.record(.invalidated([tag], reason))
        revision.bump([tag])
        center.post(Invalidated(tags: [tag], reason: reason), subject: subject)
    }

    public func sweep() async {
        guard let database else { return }
        lastSweep = clock.now
        memory.remove { $0.staleAt.addingTimeInterval($0.freshness.retention.seconds) < self.clock.now }
        if let report = try? await database.sweep(now: clock.now, cap: database.location.diskCap, retention: { $0.retention }),
           report.expired + report.evicted > 0 {
            log.log(.debug, category: "Store", "sweep expired \(report.expired) evicted \(report.evicted)")
        }
    }

    public func purge(_ freshness: FreshnessClass) async {
        memory.remove { $0.freshness == freshness }
        try? await database?.delete(freshness: freshness)
        revision.bump([])
    }

    public func purgeAll() async {
        memory.removeAll()
        try? await database?.delete(freshness: nil)
        revision.bump([])
    }

    public func statistics() async -> StoreStatistics {
        var s = (try? await database?.statistics()) ?? StoreStatistics()
        s.memoryEntries = memory.rows.count
        s.memoryBytes = memory.bytes
        return s
    }

    /// Write-through for the widget's refresher and for tests; bypasses the network.
    public func seed<V>(_ resource: Resource<V>, value: V, fetchedAt: Date? = nil) async throws {
        let payload = try WireCodec.encoder.encode(value)
        let fingerprint = pipeline.registry.fingerprint(resource.key.instance) ?? Fingerprint(rawValue: "")
        let at = fetchedAt ?? clock.now
        commit(CommittedRow(payload: payload, fetchedAt: at, staleAt: at.addingTimeInterval(resource.freshness.retention.seconds), tags: resource.tags),
               for: resource, fingerprint: fingerprint)
        await database?.flush()
    }

    // MARK: - Internals

    private func lookup(_ key: ResourceKey, fingerprint: Fingerprint?, now: Date) async -> (entry: StoredEntry, origin: CacheOrigin)? {
        guard let fingerprint else { return nil }
        if let hit = memory.get(key, fingerprint: fingerprint, now: now) { return (hit, .memory) }
        guard let database, let row = try? await database.entry(key, fingerprint: fingerprint) else { return nil }
        memory.put(row, now: now)
        try? await database.touch([key], at: now)
        return (row, .disk)
    }

    private func decode<V>(_ resource: Resource<V>, _ entry: StoredEntry, origin: CacheOrigin, isStale: Bool, degraded: MediaKitError?) throws -> Fetched<V> {
        do {
            return Fetched(value: try Self.stored(V.self, entry.payload, operation: resource.key.operation), origin: origin, fetchedAt: entry.fetchedAt, isStale: isStale, tags: entry.tags, degraded: degraded)
        } catch {
            memory.remove { $0.key == entry.key }
            throw error
        }
    }

    /// Payloads are re-encoded values, not response bytes: `Resource.decode` is for the wire only.
    private static func stored<V: Decodable>(_ type: V.Type, _ payload: Data, operation: OperationID) throws -> V {
        do { return try WireCodec.decoder.decode(V.self, from: payload) }
        catch { throw MediaKitError.decoding(operation, detail: "stored payload: " + WireCodec.describe(error)) }
    }

    private func fetch<V>(_ resource: Resource<V>, fingerprint: Fingerprint?, priority: RequestPriority) async throws -> CommittedRow {
        let key = resource.key
        let slot = key.storageKey + "|" + (fingerprint?.rawValue ?? "")
        let waiter = nextWaiter
        nextWaiter += 1
        if var existing = inFlight[slot] {
            existing.waiters.insert(waiter)
            inFlight[slot] = existing
            telemetry.record(.coalesced(key, waiters: existing.waiters.count))
        } else {
            var plan = resource.plan
            plan.priority = priority
            let task = Task { [pipeline, clock] () throws -> CommittedRow in
                let response = try await pipeline.send(plan)
                let value = try await Self.decodeOffActor(resource.decode, response.body, operation: key.operation)
                try Task.checkCancellation()
                let payload = try await Self.encodeOffActor(value)
                let now = clock.now
                if let harvest = resource.harvest { await self.identity?.record(harvest(value)) }
                return CommittedRow(payload: payload, fetchedAt: now, staleAt: now.addingTimeInterval(resource.freshness.retention.seconds), tags: resource.tags)
            }
            inFlight[slot] = InFlight(task: task, waiters: [waiter])
        }
        let task = inFlight[slot]!.task
        defer { removeWaiter(slot, waiter) }
        return try await withTaskCancellationHandler {
            let row = try await task.value
            if inFlight[slot]?.task == task, !Task.isCancelled {
                commit(row, for: resource, fingerprint: fingerprint ?? Fingerprint(rawValue: ""), slot: slot)
            }
            return row
        } onCancel: {
            Task { await self.removeWaiter(slot, waiter) }
        }
    }

    private func removeWaiter(_ slot: String, _ waiter: UInt64) {
        guard var entry = inFlight[slot] else { return }
        entry.waiters.remove(waiter)
        if entry.waiters.isEmpty {
            entry.task.cancel()
            inFlight.removeValue(forKey: slot)
        } else {
            inFlight[slot] = entry
        }
    }

    private var committed: Set<ResourceKey> = []

    private func commit<V>(_ row: CommittedRow, for resource: Resource<V>, fingerprint: Fingerprint, slot: String? = nil) {
        let entry = StoredEntry(key: resource.key, fingerprint: fingerprint, freshness: resource.freshness, payload: row.payload,
                                fetchedAt: row.fetchedAt, staleAt: row.staleAt, tags: row.tags)
        memory.put(entry, now: row.fetchedAt)
        if resource.freshness.persists, let database {
            Task { try? await database.put([entry], lastUsed: row.fetchedAt) }
        }
        if let slot { inFlight.removeValue(forKey: slot) }
        revision.bump(resource.tags)
    }

    private func scheduleRevalidation<V>(_ resource: Resource<V>) {
        guard revalidations[resource.key] == nil else { return }
        let fingerprint = pipeline.registry.fingerprint(resource.key.instance)
        revalidations[resource.key] = Task {
            _ = try? await self.fetch(resource, fingerprint: fingerprint, priority: .background)
            self.finishRevalidation(resource.key)
        }
    }

    private func finishRevalidation(_ key: ResourceKey) { revalidations.removeValue(forKey: key) }

    @concurrent
    private static func decodeOffActor<V: Sendable>(_ decode: @Sendable (Data) throws -> V, _ data: Data, operation: OperationID) async throws -> V {
        do { return try decode(data) } catch let error as MediaKitError { throw error } catch { throw MediaKitError.decoding(operation, detail: WireCodec.describe(error)) }
    }

    @concurrent
    private static func encodeOffActor<V: Encodable & Sendable>(_ value: V) async throws -> Data {
        do { return try WireCodec.encoder.encode(value) } catch { throw MediaKitError.persistence(detail: "encode: \(error)") }
    }
}

extension SQLiteDatabase {
    /// Runs behind every write already queued on the actor; tests await it before asserting rows.
    public func flush() {}
}
