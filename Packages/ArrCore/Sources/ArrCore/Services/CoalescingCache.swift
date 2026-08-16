import Foundation

/// Session-lifetime LRU that also coalesces concurrent requests for the same
/// key into one piece of work.
///
/// Three call sites had grown their own copy of this — `CastProvider`,
/// `TrailerProvider` and `SeriesIdentityResolver` — identical down to the
/// `touch`/`trim` pair and the comment explaining why misses aren't cached.
/// The rule they share is the interesting part: a *miss* is usually transient
/// (a dropped request, a key the user hasn't pasted yet, a title the metadata
/// provider doesn't know today), and caching it would pin the empty state for
/// the rest of the session. `shouldStore` is where each one says what counts
/// as a miss.
///
/// `@MainActor` rather than an actor: every user is already main-isolated, and
/// the values (`[CastMember]`, `SearchResult`) are UI-facing. Making this an
/// actor would buy nothing and add a hop per lookup.
@MainActor
final class CoalescingCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    /// Oldest first. A plain array beats a linked list at these sizes — a few
    /// dozen entries, touched once per lookup.
    private var lru: [Key] = []
    private var inflight: [Key: Task<Value, Never>] = [:]
    private let capacity: Int
    private let shouldStore: (Value) -> Bool

    init(capacity: Int, shouldStore: @escaping (Value) -> Bool = { _ in true }) {
        self.capacity = capacity
        self.shouldStore = shouldStore
    }

    /// Cached value, the in-flight one, or `work()` — in that order.
    func value(for key: Key, work: @escaping () async -> Value) async -> Value {
        if let hit = storage[key] {
            touch(key)
            return hit
        }
        if let running = inflight[key] {
            return await running.value
        }
        let task = Task { await work() }
        inflight[key] = task
        let value = await task.value
        inflight[key] = nil
        store(value, for: key)
        return value
    }

    /// Seed a value the caller obtained some other way — a resolution that
    /// answered two questions at once, say. Subject to the same `shouldStore`
    /// rule as anything the cache fetched itself.
    func store(_ value: Value, for key: Key) {
        guard shouldStore(value) else { return }
        storage[key] = value
        touch(key)
        trim()
    }

    func removeAll() {
        storage.removeAll()
        lru.removeAll()
        inflight.removeAll()
    }

    private func touch(_ key: Key) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    private func trim() {
        while lru.count > capacity {
            storage[lru.removeFirst()] = nil
        }
    }
}
