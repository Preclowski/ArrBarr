import Foundation
import Testing
@testable import MediaKit

@Suite struct CapabilityTests {
    @Test func deriveRules() {
        #expect(CapabilityProbe.derive(kind: .sonarr, statusBody: Data(#"{"version":"5.0.1.2"}"#.utf8)).capabilities == [.servarrSeasonEndpointV5])
        #expect(CapabilityProbe.derive(kind: .sonarr, statusBody: Data(#"{"version":"4.0.19"}"#.utf8)).capabilities.isEmpty)
        #expect(CapabilityProbe.derive(kind: .whisparr, statusBody: Data(#"{"version":"2.0.0"}"#.utf8)).capabilities == [.whisparrV2])
        #expect(CapabilityProbe.derive(kind: .qbittorrent, statusBody: Data(#""v5.2.3""#.utf8)).capabilities == [.qbittorrentStopStartVerbs])
        #expect(CapabilityProbe.conservativeDefault(for: .whisparr) == [.whisparrV3])
    }

    @Test func probeOncePerFingerprintAndPersisted() async throws {
        let dir = Temp.directory()
        let kit = try await TestKit(database: .file(in: dir))
        kit.transport.answer("fetchStatus", json: #"{"version":"5.1.0"}"#, instance: TestKit.sonarr)
        let set = await kit.probe.ensure(TestKit.sonarr)
        #expect(set.has(.servarrSeasonEndpointV5) && set.origin == .probe)
        _ = await kit.probe.ensure(TestKit.sonarr)
        #expect(kit.transport.count("fetchStatus") == 1)
        await kit.database!.flush()
        let cold = try await TestKit(database: .file(in: dir))
        await cold.probe.restore()
        #expect(cold.capabilities.has(.servarrSeasonEndpointV5, TestKit.sonarr))
        #expect(cold.transport.count == 0)
    }

    @Test func demoteAndPromoteAreSymmetric() async throws {
        let kit = try await TestKit()
        await kit.probe.promote(.servarrSeasonEndpointV5, for: TestKit.sonarr)
        #expect(kit.capabilities.has(.servarrSeasonEndpointV5, TestKit.sonarr))
        await kit.probe.demote(.servarrSeasonEndpointV5, for: TestKit.sonarr)
        #expect(!kit.capabilities.has(.servarrSeasonEndpointV5, TestKit.sonarr))
    }

    @Test func registryChangeInvalidatesEverything() async throws {
        let kit = try await TestKit()
        kit.transport.answer("fetchStatus", json: #"{"version":"5.1.0"}"#, instance: TestKit.sonarr)
        _ = await kit.probe.ensure(TestKit.sonarr)
        await kit.registry.apply([InstanceDescriptor(id: TestKit.sonarr, baseURL: URL(string: "http://sonarr.fixture.invalid:8080")!, generation: "g2"),
                                  InstanceDescriptor(id: TestKit.radarr, baseURL: URL(string: "http://radarr.fixture.invalid:8080")!, generation: "g1")])
        #expect(kit.capabilities.current(TestKit.sonarr).origin == .conservativeDefault)
    }
}
