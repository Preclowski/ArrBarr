import Foundation

/// The layer's memory: one entry per (provider, title), holding what that
/// provider last said, and when.
///
/// Caching *fragments* rather than merged snapshots is deliberate. A snapshot
/// is an opinion assembled from several sources with different lifetimes —
/// cache it and the ratings expire on the availability's schedule. A fragment
/// is one source's answer, so each field ages on its own class (`artwork`
/// lives for a month, `availability` for thirty seconds) and provenance
/// survives the round trip.
///
/// It also coalesces: two screens asking for the same title at the same moment
/// make one request, which is the single most common waste this layer exists
/// to remove.
public actor FragmentCache {
    public struct Entry: Sendable {
        public let fragment: MediaFragment
        public let storedAt: Date
        /// Which server/key produced it — re-point a service and its answers
        /// die with it, instead of being served for another server.
        public let fingerprint: String
    }

    private struct Key: Hashable {
        let provider: ProviderID
        let identity: String
    }

    private var storage: [Key: Entry] = [:]
    private var lru: [Key] = []
    private var inflight: [Key: Task<MediaFragment, Error>] = [:]
    private let capacity: Int
    private let telemetry: MediaTelemetry?

    public init(capacity: Int = 500, telemetry: MediaTelemetry? = nil) {
        self.capacity = capacity
        self.telemetry = telemetry
    }

    /// Fields of a cached entry that are still fresh, given each field's
    /// class. An entry is never all-or-nothing: the artwork in it can be
    /// perfectly good while the play state in it is long stale.
    private func freshFields(_ entry: Entry, now: Date) -> MediaFieldSet {
        var fresh: MediaFieldSet = []
        let age = now.timeIntervalSince(entry.storedAt)
        for field in entry.fragment.populated.fields
        where age <= field.freshnessClass.defaultTTL {
            fresh.insert(field.set)
        }
        return fresh
    }

    /// The cached answer for these fields, if every one of them is still
    /// fresh. A partial hit is reported as a miss on purpose: the provider
    /// call that refreshes the stale half returns the fresh half anyway, so
    /// splitting the request would cost a round trip and save nothing.
    /// `allowStale` serves an entry of any age — the first-paint path, where
    /// showing last night's poster instantly and refreshing behind it beats
    /// showing a spinner.
    public func cached(_ provider: ProviderID, _ identity: MediaIdentity,
                       fields: MediaFieldSet, now: Date = Date(),
                       fingerprint: String, allowStale: Bool = false) -> MediaFragment? {
        let key = Key(provider: provider, identity: identity.cacheKey)
        guard let entry = storage[key], entry.fingerprint == fingerprint else { return nil }
        let asked = fields.intersection(entry.fragment.populated)
        guard !asked.isEmpty,
              allowStale || freshFields(entry, now: now).isSuperset(of: asked) else {
            return nil
        }
        touch(key)
        return entry.fragment
    }

    public func store(_ fragment: MediaFragment, from provider: ProviderID,
                      for identity: MediaIdentity, fingerprint: String,
                      now: Date = Date()) {
        // A provider that answered nothing is not worth remembering: the miss
        // is usually transient (a dropped request, a key not pasted yet) and
        // caching it would pin the empty state for the session.
        guard !fragment.populated.isEmpty else { return }
        let key = Key(provider: provider, identity: identity.cacheKey)
        storage[key] = Entry(fragment: fragment, storedAt: now, fingerprint: fingerprint)
        touch(key)
        trim()
    }

    /// Run `work` unless the same (provider, title) call is already in
    /// flight, in which case join it.
    public func coalesced(_ provider: ProviderID, _ identity: MediaIdentity,
                          fields: MediaFieldSet,
                          work: @Sendable @escaping () async throws -> MediaFragment
    ) async throws -> MediaFragment {
        let key = Key(provider: provider, identity: identity.cacheKey)
        if let running = inflight[key] {
            await telemetry?.record(.init(kind: .coalesced, provider: provider,
                                          identity: identity.cacheKey, fields: fields))
            return try await running.value
        }
        let task = Task { try await work() }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    public func invalidate(_ identity: MediaIdentity) {
        let key = identity.cacheKey
        for stored in storage.keys where stored.identity == key {
            storage[stored] = nil
            lru.removeAll { $0 == stored }
        }
    }

    public func invalidate(provider: ProviderID) {
        for stored in storage.keys where stored.provider == provider {
            storage[stored] = nil
            lru.removeAll { $0 == stored }
        }
    }

    public func removeAll() {
        storage.removeAll()
        lru.removeAll()
    }

    public var count: Int { storage.count }

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
