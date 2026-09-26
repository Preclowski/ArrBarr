import Testing
import Foundation
@testable import MediaKit

@Suite("Indexer definitions")
struct IndexerDefinitionTests {
    private func definition(baseURL: String?) -> ArrIndexerDefinition {
        let fields = baseURL.map { [ArrIndexerDefinition.Field(name: "baseUrl", value: .string($0))] }
        return ArrIndexerDefinition(id: 7, name: "NZBgeek (Prowlarr)", fields: fields)
    }

    @Test("A Prowlarr-synced indexer carries its Prowlarr id in baseUrl")
    func prowlarrIDIsParsed() {
        #expect(definition(baseURL: "http://prowlarr:9696/14/api").prowlarrIndexerID == 14)
        #expect(definition(baseURL: "https://prowlarr.example.com/prowlarr/3/api").prowlarrIndexerID == 3)
    }

    @Test("An indexer configured by hand has no Prowlarr id to find")
    func directIndexerHasNoProwlarrID() {
        #expect(definition(baseURL: "https://api.nzbgeek.info").prowlarrIndexerID == nil)
        #expect(definition(baseURL: "http://prowlarr:9696/api/v1").prowlarrIndexerID == nil)
        #expect(definition(baseURL: nil).prowlarrIndexerID == nil)
    }
}
