import Foundation

/// Process-wide cache for the slow-changing add-form options:
/// `qualityProfiles`, `rootFolders`, `metadataProfiles`. These rarely change
/// on a running arr instance — admin edits them maybe once a year — but
/// fetching them is on the critical path every time the SearchAddPanel opens,
/// noticeably delaying the form a few hundred ms each visit.
///
/// 15-minute TTL: long enough to feel instant on repeated taps in the same
/// session, short enough that profile/folder edits in the arr UI propagate
/// within a reasonable interaction window. Keyed by source + a fingerprint
/// of the service config, so changing the arr's URL or API key naturally
/// invalidates the cached value.
@MainActor
public final class SearchOptionsCache {
    public static let shared = SearchOptionsCache()

    // Nonisolated: `Entry.isFresh` and the slot helper both read it from
    // outside the actor, and it is an immutable constant either way.
    public nonisolated static let ttl: TimeInterval = 15 * 60

    public struct Entry {
        public let profiles: [QualityProfile]
        public let folders: [RootFolder]
        public let metadataProfiles: [MetadataProfile]
        public let cachedAt: Date

        public init(profiles: [QualityProfile], folders: [RootFolder],
                    metadataProfiles: [MetadataProfile], cachedAt: Date = Date()) {
            self.profiles = profiles
            self.folders = folders
            self.metadataProfiles = metadataProfiles
            self.cachedAt = cachedAt
        }

        public var isFresh: Bool {
            Date().timeIntervalSince(cachedAt) < SearchOptionsCache.ttl
        }
    }

    /// Stored per facet rather than as one `Entry`, because the two readers
    /// want different amounts. The add panel needs all three; the profile-name
    /// lookup needs only the profiles, and if it wrote a whole `Entry` with the
    /// folders left empty, the add panel would read that back as "this arr has
    /// no root folders" and render an empty picker.
    private var profileSlots: [String: (value: [QualityProfile], at: Date)] = [:]
    private var folderSlots: [String: (value: [RootFolder], at: Date)] = [:]
    private var metadataSlots: [String: (value: [MetadataProfile], at: Date)] = [:]

    /// One in-flight fetch per arr. Without this, a screenful of Upcoming rows
    /// appearing at once each miss the cold cache and fire their own identical
    /// `/qualityprofile` request — the TTL only helps the *second* screenful.
    private var inflightProfiles: [String: Task<[QualityProfile], Never>] = [:]

    private static func fresh<V>(_ slot: (value: V, at: Date)?) -> V? {
        guard let slot, Date().timeIntervalSince(slot.at) < ttl else { return nil }
        return slot.value
    }

    public static func key(source: QueueItem.Source, config: ServiceConfig) -> String {
        // baseURL+apiKey is enough — both must match the arr we last fetched
        // from for the cached entry to apply.
        "\(source.rawValue)|\(config.baseURL)|\(config.apiKey)"
    }

    /// All three facets, and only if every one of them is still fresh — the
    /// add panel renders them together, so a partial answer is no answer.
    public func entry(for key: String) -> Entry? {
        guard let profiles = Self.fresh(profileSlots[key]),
              let folders = Self.fresh(folderSlots[key]),
              let metadata = Self.fresh(metadataSlots[key]),
              let at = profileSlots[key]?.at else { return nil }
        return Entry(profiles: profiles, folders: folders,
                     metadataProfiles: metadata, cachedAt: at)
    }

    public func store(_ entry: Entry, for key: String) {
        profileSlots[key] = (entry.profiles, entry.cachedAt)
        folderSlots[key] = (entry.folders, entry.cachedAt)
        metadataSlots[key] = (entry.metadataProfiles, entry.cachedAt)
    }

    /// Quality profiles for one arr: cached if fresh, coalesced if a fetch is
    /// already in flight, otherwise fetched via `fetch` and stored.
    ///
    /// An empty result is never cached. `/qualityprofile` failures collapse to
    /// `[]` upstream, and remembering that for 15 minutes would turn one
    /// timeout into a quarter-hour of blank profile chips.
    public func qualityProfiles(
        config: ServiceConfig,
        source: QueueItem.Source,
        fetch: @escaping @Sendable () async -> [QualityProfile]
    ) async -> [QualityProfile] {
        let key = Self.key(source: source, config: config)
        if let cached = Self.fresh(profileSlots[key]) { return cached }
        if let running = inflightProfiles[key] { return await running.value }

        let task = Task { await fetch() }
        inflightProfiles[key] = task
        let result = await task.value
        // Only clear the slot if it still holds THIS task — a concurrent
        // caller may have installed its own while we awaited.
        if inflightProfiles[key] == task { inflightProfiles[key] = nil }
        if !result.isEmpty { profileSlots[key] = (result, Date()) }
        return result
    }
}
