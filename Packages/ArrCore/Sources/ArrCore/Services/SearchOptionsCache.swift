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

    public static let ttl: TimeInterval = 15 * 60

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

    private var entries: [String: Entry] = [:]

    public static func key(source: QueueItem.Source, config: ServiceConfig) -> String {
        // baseURL+apiKey is enough — both must match the arr we last fetched
        // from for the cached entry to apply.
        "\(source.rawValue)|\(config.baseURL)|\(config.apiKey)"
    }

    public func entry(for key: String) -> Entry? {
        guard let e = entries[key], e.isFresh else { return nil }
        return e
    }

    public func store(_ entry: Entry, for key: String) {
        entries[key] = entry
    }

    /// Test seam / explicit invalidation hook. Currently unused but cheap to
    /// keep around — Settings could fire it when the user changes profiles
    /// in the arr UI and wants to see the change immediately.
    public func invalidate() {
        entries.removeAll()
    }
}
