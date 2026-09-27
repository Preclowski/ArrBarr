import Testing
import Foundation
import MediaKit
@testable import ArrCore

@Suite("Library size decoding")
struct LibrarySizeDecodingTests {
    @Test("Radarr movie decodes sizeOnDisk")
    func radarrSize() throws {
        let json = #"[{"id":1,"title":"Big Buck Bunny","hasFile":true,"sizeOnDisk":1073741824}]"#.data(using: .utf8)!
        let recs = try JSONDecoder().decode([ArrMovie].self, from: json)
        #expect(recs.first?.sizeOnDisk == 1_073_741_824)
    }

    @Test("Whisparr movie decodes sizeOnDisk")
    func whisparrSize() throws {
        let json = #"[{"id":1,"title":"Big Buck Bunny","hasFile":true,"sizeOnDisk":500}]"#.data(using: .utf8)!
        let recs = try JSONDecoder().decode([ArrMovie].self, from: json)
        #expect(recs.first?.sizeOnDisk == 500)
    }

    @Test("Sonarr series statistics decodes sizeOnDisk")
    func sonarrSize() throws {
        let json = #"[{"id":1,"statistics":{"episodeCount":10,"sizeOnDisk":2048}}]"#.data(using: .utf8)!
        let recs = try JSONDecoder().decode([SonarrLibraryRecord].self, from: json)
        #expect(recs.first?.statistics?.sizeOnDisk == 2048)
    }

    @Test("Lidarr artist statistics decodes sizeOnDisk")
    func lidarrSize() throws {
        let json = #"[{"artistName":"X","statistics":{"albumCount":3,"sizeOnDisk":4096}}]"#.data(using: .utf8)!
        let recs = try JSONDecoder().decode([LidarrLibraryRecord].self, from: json)
        #expect(recs.first?.statistics?.sizeOnDisk == 4096)
    }

    @Test("Missing sizeOnDisk decodes to nil, not a failure")
    func missingSize() throws {
        let json = #"[{"id":1,"title":"Big Buck Bunny","hasFile":false}]"#.data(using: .utf8)!
        let recs = try JSONDecoder().decode([ArrMovie].self, from: json)
        #expect(recs.first?.sizeOnDisk == nil)
    }
}
