import Foundation
import os

public actor ResourceStore {
    private struct InFlight {
        let task: Task<CommittedRow, any Error>
        let instance: InstanceID
        let tags: Set<InvalidationTag>
        var waiters: Set<UInt64> = []
    }

    struct CommittedRow: Sendable {
        /// The fetched value itself, so the waiters of that fetch don't decode the payload it was just encoded to.
        let value: any Sendable
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
    /// Disk writes land in the order they were issued: a row put before an invalidation must not land after it.
    private var diskQueue: Task<Void, Never>?
    /// Command ids are per arr: Sonarr's command 42 is not Radarr's.
    private struct TrackedCommand: Hashable { let instance: InstanceID; let id: Int }
    private var commandTrackers: [TrackedCommand: Task<Void, Never>] = [:]
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

    // MARK: - Reads

    public func read<V>(_ resource: Resource<V>, policy requested: ReadPolicy = .cacheFirst, maxAge: Duration? = nil,
                        priority: RequestPriority = .interactive) async throws -> Fetched<V> {
        let policy = policyOverride ?? requested
        let now = clock.now
        let fingerprint = pipeline.registry.fingerprint(resource.key.instance)
        let cached = await lookup(resource.key, fingerprint: fingerprint, now: now)
        let ttl = min(resource.effectiveTTL.seconds, maxAge?.seconds ?? .infinity)
        // Two different kinds of "not fresh": the TTL ran out (possibly old), or a command or event marked the row
        // (known changed). Only the first is safe to hand back while revalidating behind the caller's back.
        let invalidated = cached.map { now >= $0.entry.staleAt } ?? false
        let fresh = (cached.map { now < $0.entry.fetchedAt.addingTimeInterval(ttl) } ?? false) && !invalidated

        switch policy {
        case .cacheOnly:
            guard let cached else { throw MediaKitError.notConfigured(resource.key.instance) }
            telemetry.record(.cacheHit(resource.key, cached.origin))
            return try await decode(resource, cached.entry, origin: cached.origin, isStale: !fresh, degraded: nil)
        case .cacheFirst where fresh, .staleWhileRevalidate where fresh:
            telemetry.record(.cacheHit(resource.key, cached!.origin))
            return try await decode(resource, cached!.entry, origin: cached!.origin, isStale: false, degraded: nil)
        case .staleWhileRevalidate where !invalidated:
            if let cached {
                telemetry.record(.cacheHit(resource.key, cached.origin))
                scheduleRevalidation(resource)
                return try await decode(resource, cached.entry, origin: cached.origin, isStale: true, degraded: nil)
            }
        default:
            break
        }
        telemetry.record(.cacheMiss(resource.key))
        do {
            let row = try await fetch(resource, fingerprint: fingerprint, priority: priority)
            let value: V
            if let fetched = row.value as? V { value = fetched } else { value = try await Self.stored(V.self, row.payload, operation: resource.key.operation) }
            return Fetched(value: value, origin: .network,
                           fetchedAt: row.fetchedAt, isStale: false, degraded: nil)
        } catch let error as MediaKitError {
            if policy != .mustRevalidate, let cached {
                telemetry.record(.staleServed(resource.key, error))
                return try await decode(resource, cached.entry, origin: cached.origin, isStale: true, degraded: error)
            }
            throw error
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

    public func run(_ command: Command) async throws -> CommandReceipt {
        let context = CommandContext(pipeline: pipeline, probe: probe, capabilities: capabilities, clock: clock)
        let receipt = try await command.run(context)
        await invalidate(command.invalidates, reason: .command)
        if case let .arrCommand(timeout)? = command.tracking, let id = receipt.trackingID {
            track(commandID: id, instance: command.instance, invalidates: command.invalidates, timeout: timeout)
        }
        return receipt
    }

    private func track(commandID: Int, instance: InstanceID, invalidates: Set<InvalidationTag>, timeout: Duration) {
        let key = TrackedCommand(instance: instance, id: commandID)
        commandTrackers[key]?.cancel()
        commandTrackers[key] = Task { [clock, pipeline] in
            let deadline = clock.now.addingTimeInterval(timeout.seconds)
            let api = ServarrProfile.profile(for: instance.kind)?.apiBase ?? "/api/v3"
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
            // A cancelled tracker was replaced under the same key; the new one stays.
            if !Task.isCancelled { self.forgetTracker(key) }
        }
    }

    private func forgetTracker(_ key: TrackedCommand) { commandTrackers.removeValue(forKey: key) }

    // MARK: - Invalidation and maintenance

    public func invalidate(_ tags: Set<InvalidationTag>, reason: InvalidationReason) async {
        guard !tags.isEmpty else { return }
        let now = clock.now
        memory.markStale(tags: tags, at: now)
        detachFetches { !$0.tags.isDisjoint(with: tags) }
        await onDisk { _ = try? await $0.markStale(tags: tags, at: now) }?.value
        telemetry.record(.invalidated(tags, reason))
        if reason != .sweep { log.log(.debug, category: "Store", "invalidate \(tags.count) tags (\(reason.rawValue))") }
        revision.bump(tags)
        center.post(Invalidated(tags: tags), subject: subject)
    }

    public func invalidate(instance: InstanceID, reason: InvalidationReason) async {
        let now = clock.now
        memory.markStale(instance: instance, at: now)
        detachFetches { $0.instance == instance }
        await onDisk { _ = try? await $0.markStale(instance: instance, at: now) }?.value
        let tag = InvalidationTag.instance(instance)
        telemetry.record(.invalidated([tag], reason))
        revision.bump([tag])
        center.post(Invalidated(tags: [tag]), subject: subject)
    }

    public func sweep() async {
        guard let database else { return }
        memory.remove { $0.staleAt.addingTimeInterval($0.freshness.retention.seconds) < self.clock.now }
        if let report = try? await database.sweep(now: clock.now, cap: database.location.diskCap, retention: { $0.retention }),
           report.expired + report.evicted > 0 {
            log.log(.debug, category: "Store", "sweep expired \(report.expired) evicted \(report.evicted)")
        }
    }

    public func purgeAll() async {
        memory.removeAll()
        detachFetches { _ in true }
        await onDisk { try? await $0.delete(freshness: nil) }?.value
        revision.bumpEverything()
    }

    /// Returns once every disk write issued so far has landed.
    public func flush() async { await diskQueue?.value }

    public func statistics() async -> StoreStatistics {
        var s = (try? await database?.statistics()) ?? StoreStatistics()
        s.memoryEntries = memory.rows.count
        s.memoryBytes = memory.bytes
        return s
    }

    // MARK: - Internals

    /// A fetch sent before a write would bring back the pre-write rows as fresh. Its waiters still get them (they
    /// asked first), but it is no longer joined or committed: the next read starts its own.
    private func detachFetches(_ affected: (InFlight) -> Bool) {
        inFlight = inFlight.filter { !affected($0.value) }
    }

    @discardableResult
    private func onDisk(_ work: @escaping @Sendable (SQLiteDatabase) async -> Void) -> Task<Void, Never>? {
        guard let database else { return nil }
        let previous = diskQueue
        let task = Task { await previous?.value; await work(database) }
        diskQueue = task
        return task
    }

    private func lookup(_ key: ResourceKey, fingerprint: Fingerprint?, now: Date) async -> (entry: StoredEntry, origin: CacheOrigin)? {
        guard let fingerprint else { return nil }
        if let hit = memory.get(key, fingerprint: fingerprint, now: now) { return (hit, .memory) }
        guard let database, let row = try? await database.entry(key, fingerprint: fingerprint) else { return nil }
        memory.put(row, now: now)
        try? await database.touch([key], at: now)
        return (row, .disk)
    }

    private func decode<V>(_ resource: Resource<V>, _ entry: StoredEntry, origin: CacheOrigin, isStale: Bool, degraded: MediaKitError?) async throws -> Fetched<V> {
        do {
            return Fetched(value: try await Self.stored(V.self, entry.payload, operation: resource.key.operation), origin: origin, fetchedAt: entry.fetchedAt, isStale: isStale, degraded: degraded)
        } catch {
            memory.remove { $0.key == entry.key }
            throw error
        }
    }

    /// Payloads are re-encoded values, not response bytes: `Resource.decode` is for the wire only. Off the actor:
    /// a large library takes tens of milliseconds, which every other read would otherwise queue behind.
    @concurrent
    private static func stored<V: Decodable & Sendable>(_ type: V.Type, _ payload: Data, operation: OperationID) async throws -> V {
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
                return CommittedRow(value: value, payload: payload, fetchedAt: now, staleAt: now.addingTimeInterval(resource.validFor.seconds), tags: resource.tags)
            }
            inFlight[slot] = InFlight(task: task, instance: key.instance, tags: resource.tags, waiters: [waiter])
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

    private func commit<V>(_ row: CommittedRow, for resource: Resource<V>, fingerprint: Fingerprint, slot: String? = nil) {
        let entry = StoredEntry(key: resource.key, fingerprint: fingerprint, freshness: resource.freshness, payload: row.payload,
                                fetchedAt: row.fetchedAt, staleAt: row.staleAt, tags: row.tags)
        memory.put(entry, now: row.fetchedAt)
        if resource.freshness.persists {
            onDisk { try? await $0.put([entry], lastUsed: row.fetchedAt) }
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
    // periphery:ignore
    public func flush() {}
}
