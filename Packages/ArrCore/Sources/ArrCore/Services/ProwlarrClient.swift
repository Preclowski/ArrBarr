import Foundation
import MediaKit

/// Prowlarr's facade — the one door to `ProwlarrService`, like `RadarrClient`
/// is for Radarr. Unlike the arrs there is no Settings draft to adopt (the
/// gateway builds the single saved instance from `ConfigStore.prowlarr`), so
/// this carries no config and simply resolves that instance.
///
/// ArrBarr asks Prowlarr two things: whether it answers (Settings' test, the
/// connection-health probe) and what the user named an indexer.
nonisolated public struct ProwlarrClient: Sendable {
    public init() {}

    /// The indexers as Prowlarr knows them. Reference data with a long life in
    /// the store, read through by `IndexerNames`.
    public func indexers() async throws -> [ProwlarrIndexer] {
        let c = try await context()
        return try await c.gateway.store.read(c.service.indexers()).value
    }

    /// One round trip proving the server answers and the key is accepted;
    /// returns the same version line the arrs' test shows.
    public func testConnection() async throws -> String {
        let c = try await context()
        let status = try await c.gateway.store.read(c.service.status(), policy: .mustRevalidate).value
        return status.version.map { "Prowlarr \($0)" } ?? "OK"
    }

    private func context() async throws -> (gateway: ServiceGateway, service: ProwlarrService) {
        let gateway = await ServiceGateway.resolve()
        await gateway.ready()
        guard let service = await gateway.prowlarr else { throw ProwlarrNotConfigured() }
        return (gateway, service)
    }
}
