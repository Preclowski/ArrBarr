import Testing
import Foundation
import MediaKit
@testable import ArrCore

/// Demo mode is the bundled fixtures behind placeholder origins: every enabled arr answers queue, calendar and
/// history without a host. The gateway is built as a demo one directly, so the global flag stays untouched.
@Suite("Demo data flow")
struct DemoDataFlowTests {
    @MainActor
    private func makeGateway() -> ServiceGateway {
        let store = ConfigStore(defaults: UserDefaults(suiteName: "ArrCoreTests.demo.\(UUID().uuidString)")!, secrets: InMemorySecretStore())
        for kind in [ServiceKind.radarr, .sonarr, .lidarr, .whisparr] {
            var config = ServiceConfig.empty
            config.enabled = true
            store.update(kind, with: config)
        }
        store.mediaServer = MediaServerConfig(enabled: true, kind: .plex)
        return ServiceGateway(configStore: store, demo: true)
    }

    @Test("Every arr flavour serves queue, upcoming and history from fixtures", arguments: [QueueItem.Source.radarr, .sonarr, .lidarr, .whisparr])
    func arrFlows(source: QueueItem.Source) async throws {
        let gateway = await makeGateway()
        let base = ServiceGateway.demoURL(source.serviceKind.instanceKind).absoluteString
        let queue = try await ArrQueueLoader.items(source: source, gateway: gateway, baseURL: base)
        let upcoming = try await ArrQueueLoader.upcoming(source: source, gateway: gateway, baseURL: base)
        let history = try await ArrQueueLoader.history(source: source, gateway: gateway, baseURL: base, page: 1, pageSize: 20, entityId: nil)
        #expect(!queue.isEmpty)
        #expect(!upcoming.isEmpty)
        #expect(!history.items.isEmpty)
        #expect(queue.allSatisfy { !$0.title.isEmpty })
        await gateway.kit.stop()
    }
}
