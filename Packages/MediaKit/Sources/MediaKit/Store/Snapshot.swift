import Foundation
import Observation
import os

/// Synchronous, lock-guarded projection for view bodies; rebuilt off the caller on every matching bump.
public final class Snapshot<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<(value: Value, version: UInt64)>
    private let tags: Set<InvalidationTag>
    private let store: ResourceStore
    private let rebuild: @Sendable (ResourceStore) async -> Value
    private let didRebuild: (@Sendable (Value) -> Void)?
    private let settle: Duration
    private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// `didRebuild` runs after each new value is readable through `current`, for a consumer that caches something derived from it.
    /// `settle` waits after a bump so a burst of commits (a revalidation touching several of the tags) rebuilds once.
    public init(tags: Set<InvalidationTag>, initial: Value, store: ResourceStore, settle: Duration = .zero,
                didRebuild: (@Sendable (Value) -> Void)? = nil, rebuild: @escaping @Sendable (ResourceStore) async -> Value) {
        state = OSAllocatedUnfairLock(initialState: (initial, 0))
        self.tags = tags; self.store = store; self.rebuild = rebuild; self.didRebuild = didRebuild; self.settle = settle
    }

    public var current: (value: Value, version: UInt64) { state.withLock { $0 } }

    public func start() async {
        let tags = self.tags
        let revision = store.revision
        let ticks: @Sendable () -> UInt64 = { revision.tick(for: tags) }
        let initial = ticks()
        await refresh()
        let settle = self.settle
        task.withLock { existing in
            existing?.cancel()
            existing = Task { [weak self] in
                var built = initial
                for await _ in Observations(ticks) {
                    if settle > .zero { try? await Task.sleep(for: settle) }
                    guard let self, !Task.isCancelled else { break }
                    // Bumps that landed while settling were already seen by this read; their own wake-up finds nothing new.
                    let now = ticks()
                    guard now != built else { continue }
                    built = now
                    await self.refresh()
                }
            }
        }
    }

    public func stop() { task.withLock { $0?.cancel(); $0 = nil } }

    private func refresh() async {
        let value = await rebuild(store)
        state.withLock { $0 = (value, $0.version + 1) }
        didRebuild?(value)
    }
}
