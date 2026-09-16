import Foundation
import Observation
import os

/// Synchronous, lock-guarded projection for view bodies; rebuilt off the caller on every matching bump.
public final class Snapshot<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<(value: Value, version: UInt64)>
    private let tags: Set<InvalidationTag>
    private let store: ResourceStore
    private let rebuild: @Sendable (ResourceStore) async -> Value
    private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    public init(tags: Set<InvalidationTag>, initial: Value, store: ResourceStore, rebuild: @escaping @Sendable (ResourceStore) async -> Value) {
        state = OSAllocatedUnfairLock(initialState: (initial, 0))
        self.tags = tags; self.store = store; self.rebuild = rebuild
    }

    public var current: (value: Value, version: UInt64) { state.withLock { $0 } }

    public func start() async {
        await refresh()
        let tags = self.tags
        let revision = store.revision
        task.withLock { existing in
            existing?.cancel()
            existing = Task { [weak self] in
                for await _ in Observations({ tags.reduce(UInt64(0)) { $0 &+ revision.tick(for: $1) } }) {
                    guard let self, !Task.isCancelled else { break }
                    await self.refresh()
                }
            }
        }
    }

    public func stop() { task.withLock { $0?.cancel(); $0 = nil } }

    private func refresh() async {
        let value = await rebuild(store)
        state.withLock { $0 = (value, $0.version + 1) }
    }
}
