import Foundation
import MediaKit
import Testing
@testable import ArrCore

private final class QueueRows: @unchecked Sendable {
    private let lock = NSLock()
    private var json = "[]"
    var value: String {
        get { lock.withLock { json } }
        set { lock.withLock { json = newValue } }
    }
}

/// A command's effects reach the gateway's queue stream: the row changes at once and stays changed until the arr agrees.
@Suite("Queue command effects", .serialized)
struct QueueEffectsTests {
    private static func record(_ id: Int, status: String, downloadId: String? = nil, episodeId: Int = 11) -> String {
        let download = downloadId.map { #","downloadId":"\#($0)""# } ?? ""
        return #"{"id":\#(id),"seriesId":7,"episodeId":\#(episodeId),"title":"Big Buck Bunny","status":"\#(status)"\#(download)}"#
    }

    private static func gateway(rows: QueueRows) async -> ServiceGateway {
        let transport = ScriptedTransport { request in
            if request.url.path.hasSuffix("/queue") { return .init(#"{"page":1,"pageSize":1000,"totalRecords":1,"records":\#(rows.value)}"#) }
            if request.url.path.contains("/system/status") { return .init(#"{"version":"4.0.0"}"#) }
            return .init("{}")
        }
        return await MainActor.run {
            let hadCurrent = ServiceGateway.current != nil
            let store = ConfigStore(defaults: TestDefaults.suite("ArrCoreTests.effects.\(UUID())"), secrets: InMemorySecretStore())
            store.update(.sonarr, with: ServiceConfig(enabled: true, baseURL: "http://effects.test:8989", apiKey: "k", username: "", password: ""))
            let gateway = ServiceGateway(configStore: store, demo: false, transport: transport)
            store.gateway = gateway
            if !hadCurrent { ServiceGateway.current = nil }
            return gateway
        }
    }

    @Test("Delete hides the row at once, and it stays hidden while the arr catches up")
    func deleteHidesTheRow() async throws {
        let rows = QueueRows()
        rows.value = "[\(Self.record(1, status: "downloading", downloadId: "ABC"))]"
        let gateway = await Self.gateway(rows: rows)
        await gateway.ready()
        let stream = gateway.queueStream(.sonarr)
        await stream.refreshNow()
        #expect(stream.last()?.elements.map(\.id) == [1])

        try await gateway.run(gateway.servarr(.sonarr).deleteQueueItem(id: 1, removeFromClient: true, blocklist: false))
        #expect(stream.last()?.elements.isEmpty == true)
        await stream.refreshNow()
        #expect(stream.last()?.elements.isEmpty == true)
    }

    @Test("A grabbed pending release stays on screen until its download turns up under a new id")
    func grabbedPendingReleaseHandsOver() async throws {
        let rows = QueueRows()
        rows.value = "[\(Self.record(1, status: "delay"))]"
        let gateway = await Self.gateway(rows: rows)
        await gateway.ready()
        let stream = gateway.queueStream(.sonarr)
        await stream.refreshNow()

        try await gateway.run(gateway.servarr(.sonarr).grabQueueItem(id: 1))
        #expect(stream.last()?.elements.first?.status == "downloading")
        rows.value = "[]"
        await stream.refreshNow()
        #expect(stream.last()?.elements.map(\.id) == [1])
        rows.value = "[\(Self.record(2, status: "downloading", downloadId: "NZO"))]"
        await stream.refreshNow()
        #expect(stream.last()?.elements.map(\.id) == [2])
    }

    @Test("A download-client pause names the arr row by its download id")
    func downloadClientEffectFindsTheArrRow() async throws {
        let rows = QueueRows()
        rows.value = "[\(Self.record(1, status: "downloading", downloadId: "ABC"))]"
        let gateway = await Self.gateway(rows: rows)
        await gateway.ready()
        let stream = gateway.queueStream(.sonarr)
        await stream.refreshNow()

        let pause = Command(name: OperationID(.qbittorrent, "pause"), instance: InstanceID(.qbittorrent), invalidates: [],
                            effects: [PendingEffect(elementID: "abc", change: .status("paused"))]) { ctx in CommandReceipt(acceptedAt: ctx.clock.now) }
        try await gateway.run(pause)
        #expect(stream.last()?.elements.first?.status == "paused")
    }
}
