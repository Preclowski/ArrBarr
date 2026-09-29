import Foundation
import Testing
@testable import MediaKit

@Suite struct DetailActionRequestTests {
    @Test func episodeFileDeleteRemovesOnlyTheFile() async throws {
        let kit = try await TestKit()
        _ = try await kit.store.run(kit.servarr(TestKit.sonarr).deleteFile(id: 42, parent: 7))
        let request = try #require(kit.transport.requests.last)
        #expect(request.method == "DELETE" && request.pathTemplate == "/api/v3/episodefile/{id}" && request.url.path == "/api/v3/episodefile/42")
    }

    @Test func albumDeleteCarriesBothFlags() async throws {
        let lidarr = InstanceID(.lidarr)
        let kit = try await TestKit(instances: [lidarr])
        _ = try await kit.store.run(kit.servarr(lidarr).deleteAlbum(id: 5, artistID: 2, deleteFiles: true, addImportListExclusion: false))
        let request = try #require(kit.transport.requests.last)
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(request.method == "DELETE" && request.url.path == "/api/v1/album/5")
        #expect(query.contains(URLQueryItem(name: "deleteFiles", value: "true")))
        #expect(query.contains(URLQueryItem(name: "addImportListExclusion", value: "false")))
    }

    @Test func recordHistoryPagesAndTakesFilters() {
        let sonarr = ServarrService(instance: TestKit.sonarr, profile: .sonarr, capabilities: CapabilityIndex())
        let query = sonarr.historyFor(entityID: 3, page: 2, pageSize: 100, filters: [("episodeId", "9")]).plan.query
        #expect(query.contains(.init("page", "2")) && query.contains(.init("seriesIds", "3")) && query.contains(.init("episodeId", "9")))
        let lidarr = ServarrService(instance: InstanceID(.lidarr), profile: .lidarr, capabilities: CapabilityIndex())
        #expect(lidarr.history(filters: [("artistIds", "4")]).plan.query.contains(.init("artistIds", "4")))
    }
}
