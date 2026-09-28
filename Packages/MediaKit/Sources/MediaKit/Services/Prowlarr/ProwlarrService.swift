import Foundation

/// Prowlarr's own name for an indexer, before the arrs add their suffixes.
public struct ProwlarrIndexer: Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String?
    /// Fallback label when the instance has no name ("Newznab", "Torznab").
    public let implementation: String?
    public let enable: Bool?
}

public struct ProwlarrService: Sendable {
    public let instance: InstanceID

    public init(instance: InstanceID = InstanceID(.prowlarr)) {
        self.instance = instance
    }

    private func plan(_ operation: String, path: String) -> RequestPlan {
        RequestPlan(instance: instance, operation: operation, pathTemplate: "/api/v1" + path, auth: .header("X-Api-Key"))
    }

    /// Reference data: names change only when the server is reconfigured.
    public func indexers() -> Resource<[ProwlarrIndexer]> {
        .json(plan("indexers", path: "/indexer"), tags: [.collection(.lookup, instance)], freshness: .reference, ttl: .seconds(3600))
    }

    public func status() -> Resource<ArrSystemStatus> {
        .json(plan("testConnection", path: "/system/status"), tags: [.capabilities(instance)], freshness: .reference)
    }
}
