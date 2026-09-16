import Foundation
import Observation
import os

/// Lock-guarded, not an actor: bodies run on the caller, never serialised on an engine actor.
public final class CompositionEngine: Sendable {
    private struct Memo: Sendable { let value: any Sendable; let tags: Set<InvalidationTag>; let complete: Bool; let revision: UInt64 }
    /// AnyHashable is not Sendable; inputs are small values, so their reflected text is the key.
    private struct MemoKey: Hashable, Sendable {
        let type: ObjectIdentifier
        let text: String
        init<Input: Hashable>(_ input: Input) { type = ObjectIdentifier(Input.self); text = String(reflecting: input) }
    }

    let store: ResourceStore
    let identity: IdentityStore
    let capabilities: CapabilityIndex
    let clock: any MediaClock
    let telemetry: any TelemetrySink
    private let memos = OSAllocatedUnfairLock<[MemoKey: Memo]>(initialState: [:])

    public init(store: ResourceStore, identity: IdentityStore, capabilities: CapabilityIndex, clock: any MediaClock, telemetry: any TelemetrySink) {
        self.store = store; self.identity = identity; self.capabilities = capabilities; self.clock = clock; self.telemetry = telemetry
    }

    /// Memoised on `input` in memory; dropped when any tag in its provenance is bumped.
    public func compose<Input: Hashable & Sendable, Value: Sendable>(
        _ input: Input, priority: RequestPriority = .interactive, policy: ReadPolicy = .cacheFirst,
        _ body: @Sendable @escaping (CompositionContext) async throws -> Value) async throws -> Composed<Value> {
        let key = MemoKey(input)
        if policy != .mustRevalidate, let memo = memos.withLock({ $0[key] }), memo.complete,
           memo.revision == stamp(memo.tags), let value = memo.value as? Composed<Value> {
            return value
        }
        let context = CompositionContext(store: store, identity: identity, capabilities: capabilities, priority: priority, policy: policy)
        let value = try await body(context)
        let provenance = context.provenance
        let composed = Composed(value: value, provenance: provenance)
        memos.withLock { $0[key] = Memo(value: composed, tags: provenance.tags, complete: provenance.isComplete, revision: stamp(provenance.tags)) }
        return composed
    }

    /// Many inputs under one limiter budget; bodies run concurrently.
    public func values<Input: Hashable & Sendable, Value: Sendable>(
        _ inputs: [Input], priority: RequestPriority = .interactive,
        _ body: @Sendable @escaping (Input, CompositionContext) async throws -> Value) async -> [Input: Result<Composed<Value>, MediaKitError>] {
        await withTaskGroup(of: (Input, Result<Composed<Value>, MediaKitError>).self) { group in
            for input in inputs {
                group.addTask {
                    do { return (input, .success(try await self.compose(input, priority: priority) { try await body(input, $0) })) }
                    catch let error as MediaKitError { return (input, .failure(error)) }
                    catch { return (input, .failure(.persistence(detail: "\(error)"))) }
                }
            }
            var out: [Input: Result<Composed<Value>, MediaKitError>] = [:]
            for await (input, result) in group { out[input] = result }
            return out
        }
    }

    /// First build → one element per bump touching the provenance.
    public func observe<Input: Hashable & Sendable, Value: Sendable>(
        _ input: Input, priority: RequestPriority = .interactive,
        _ body: @Sendable @escaping (CompositionContext) async throws -> Value) -> AsyncStream<Composed<Value>> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var tags: Set<InvalidationTag> = []
                var lastStamp: UInt64?
                let revision = store.revision
                while !Task.isCancelled {
                    if let composed = try? await self.compose(input, priority: priority, policy: .cacheFirst, body) {
                        tags = composed.provenance.tags
                        continuation.yield(composed)
                    }
                    let watched = tags
                    let observations = Observations { watched.reduce(UInt64(0)) { $0 &+ revision.tick(for: $1) } }
                    var iterator = observations.makeAsyncIterator()
                    let current = await iterator.next()
                    if let current, let lastStamp, current != lastStamp { continue }
                    lastStamp = current
                    guard let next = await iterator.next(), !Task.isCancelled else { break }
                    lastStamp = next
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func forget<Input: Hashable & Sendable>(_ input: Input) { memos.withLock { _ = $0.removeValue(forKey: MemoKey(input)) } }

    private func stamp(_ tags: Set<InvalidationTag>) -> UInt64 { tags.reduce(UInt64(0)) { $0 &+ store.revision.tick(for: $1) } }
}
