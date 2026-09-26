import Foundation

/// One indexer as Prowlarr knows it — the name the user gave it there, before
/// the *arrs decorate it with wherever-it-came-from suffixes.
public struct ProwlarrIndexer: Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String?
    /// "Newznab", "Torznab", … — what kind of indexer this is. Only used as a
    /// fallback label when the instance has no name of its own.
    public let implementation: String?
    public let enable: Bool?
}

/// Prowlarr's slice of the API: the indexer list, and the status call every
/// service needs for "test connection". ArrBarr asks it one question — what is
/// this indexer really called — so there is nothing else here.
public struct ProwlarrService: Sendable {
    public let instance: InstanceID

    public init(instance: InstanceID = InstanceID(.prowlarr)) {
        self.instance = instance
    }

    private func plan(_ operation: String, path: String) -> RequestPlan {
        RequestPlan(instance: instance, operation: operation, pathTemplate: "/api/v1" + path, auth: .header("X-Api-Key"))
    }

    /// The configured indexers. Names change about as often as the server is
    /// reconfigured, so this is reference data with a long life in the store.
    public func indexers() -> Resource<[ProwlarrIndexer]> {
        .json(plan("indexers", path: "/indexer"), tags: [.collection(.lookup, instance)], freshness: .reference, ttl: .seconds(3600))
    }

    public func status() -> Resource<ArrSystemStatus> {
        .json(plan("testConnection", path: "/system/status"), tags: [.capabilities(instance)], freshness: .reference)
    }
}
