import Foundation
import os

public struct Provenance: Sendable, Equatable {
    public var tags: Set<InvalidationTag> = []
    public var oldestFetch: Date?
    public var origins: [CacheOrigin: Int] = [:]
    public var failures: [ResourceKey: MediaKitError] = [:]
    public init() {}

    public var isComplete: Bool { failures.isEmpty }
    public var isOffline: Bool {
        !failures.isEmpty && failures.values.allSatisfy { $0.caseName == "unreachable" || $0.caseName == "breakerOpen" }
    }
}

public struct Composed<Value: Sendable>: Sendable {
    public let value: Value
    public let provenance: Provenance
    public init(value: Value, provenance: Provenance) { self.value = value; self.provenance = provenance }
}

/// One per build; Sendable so a body can `async let` fan out. Accumulators sit behind a lock.
public final class CompositionContext: Sendable {
    public let priority: RequestPriority
    public let policy: ReadPolicy
    let store: ResourceStore
    let identity: IdentityStore
    let capabilities: CapabilityIndex
    private let accumulator = OSAllocatedUnfairLock(initialState: Provenance())

    init(store: ResourceStore, identity: IdentityStore, capabilities: CapabilityIndex, priority: RequestPriority, policy: ReadPolicy) {
        self.store = store; self.identity = identity; self.capabilities = capabilities; self.priority = priority; self.policy = policy
    }

    public func read<V>(_ r: Resource<V>, maxAge: Duration? = nil) async throws -> V {
        do {
            let fetched = try await store.read(r, policy: policy, maxAge: maxAge, priority: priority)
            note(fetched)
            return fetched.value
        } catch let error as MediaKitError {
            accumulator.withLock { $0.failures[r.key] = error; $0.tags.formUnion(r.tags) }
            throw error
        }
    }

    /// A failure is recorded, not thrown.
    public func optional<V>(_ r: Resource<V>, maxAge: Duration? = nil) async -> V? {
        try? await read(r, maxAge: maxAge)
    }

    public func batch<K: Comparable, V>(_ b: BatchResource<K, V>, keys: [K], maxAge: Duration? = nil) async -> [K: [V]] {
        let results = await store.batch(b, keys: keys, policy: policy, maxAge: maxAge, priority: priority)
        var out: [K: [V]] = [:]
        for (key, result) in results {
            switch result {
            case let .success(v): out[key] = v
            case let .failure(error):
                accumulator.withLock { $0.failures[ResourceKey(instance: InstanceID(.radarr), operation: "batch", discriminator: "\(key)")] = error }
            }
        }
        return out
    }

    public func known(_ id: MediaID, in namespace: IDNamespace) async -> MediaID? { await identity.known(id, in: namespace) }
    public func has(_ c: Capability, _ instance: InstanceID) -> Bool { capabilities.has(c, instance) }
    public var provenance: Provenance { accumulator.withLock { $0 } }

    private func note<V>(_ fetched: Fetched<V>) {
        accumulator.withLock { p in
            p.tags.formUnion(fetched.tags)
            p.origins[fetched.origin, default: 0] += 1
            p.oldestFetch = min(p.oldestFetch ?? fetched.fetchedAt, fetched.fetchedAt)
            if let degraded = fetched.degraded, let key = fetched.tags.first.map({ ResourceKey(instance: InstanceID(.radarr), operation: OperationID(stringLiteral: $0.rawValue)) }) {
                p.failures[key] = degraded
            }
        }
    }
}
