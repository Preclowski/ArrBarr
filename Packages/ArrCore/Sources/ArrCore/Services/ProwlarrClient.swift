import Foundation
import MediaKit

/// No Settings draft to adopt: the gateway builds the single saved instance from `ConfigStore.prowlarr`.
nonisolated public struct ProwlarrClient: Sendable {
    public init() {}

    public func indexers() async throws -> [ProwlarrIndexer] {
        let c = try await context()
        return try await c.gateway.store.read(c.service.indexers()).value
    }

    public func testConnection() async throws -> String {
        let c = try await context()
        let status = try await c.gateway.store.read(c.service.status(), policy: .mustRevalidate).value
        return status.version.map { "Prowlarr \($0)" } ?? String(localized: "common.ok.label", bundle: .module)
    }

    private func context() async throws -> (gateway: ServiceGateway, service: ProwlarrService) {
        let gateway = await ServiceGateway.resolve()
        await gateway.ready()
        guard let service = await gateway.prowlarr else { throw ProwlarrNotConfigured() }
        return (gateway, service)
    }
}
