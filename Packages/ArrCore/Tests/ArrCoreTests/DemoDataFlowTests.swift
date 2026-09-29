import Testing
import Foundation
import MediaKit
@testable import ArrCore

/// Demo mode is the bundled fixtures behind placeholder origins: every enabled arr answers queue, calendar and
/// history without a host. `ServiceGateway.demo` builds it, so the global flag stays untouched.
@Suite("Demo data flow")
struct DemoDataFlowTests {
    @MainActor
    private func makeGateway() -> ServiceGateway {
        let gateway = ServiceGateway.demo(kinds: [.radarr, .sonarr, .lidarr, .whisparr])
        gateway.configStore.mediaServer = MediaServerConfig(enabled: true, kind: .plex)
        return gateway
    }

    @Test("Every arr flavour serves queue, upcoming and history from fixtures", arguments: [QueueItem.Source.radarr, .sonarr, .lidarr, .whisparr])
    func arrFlows(source: QueueItem.Source) async throws {
        let gateway = await makeGateway()
        let base = ServiceGateway.demoURL(source.serviceKind.instanceKind).absoluteString
        let queue = try await ArrQueueLoader.items(source: source, gateway: gateway, baseURL: base)
        let upcoming = try await ArrQueueLoader.upcoming(source: source, gateway: gateway, baseURL: base)
        let history = try await ArrQueueLoader.history(source: source, gateway: gateway, baseURL: base, page: 1, pageSize: 20, scope: nil)
        #expect(!queue.isEmpty)
        #expect(!upcoming.isEmpty)
        #expect(!history.items.isEmpty)
        #expect(queue.allSatisfy { !$0.title.isEmpty })
        await gateway.kit.stop()
    }

    @Test("The demo download clients answer the health probe and a pause", arguments: [ServiceKind.qbittorrent, .sabnzbd])
    func downloadClientsAnswer(kind: ServiceKind) async throws {
        let gateway = await MainActor.run { ServiceGateway.demo(kinds: [kind]) }
        let config = await MainActor.run { gateway.configStore.config(for: kind) }
        try await ServiceGateway.$override.withValue(gateway) {
            _ = try await ServiceHandles.testConnection(kind, config: config)
            let service = try #require(gateway.download(kind))
            try await gateway.run(service.action(.pause, ids: ["abc"], deleteFiles: false))
        }
        await gateway.kit.stop()
    }
}
