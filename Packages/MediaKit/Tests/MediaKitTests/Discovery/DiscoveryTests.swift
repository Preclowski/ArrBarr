import Testing
import Foundation
@testable import MediaKit

/// Criterion 25: the parsers behind Bonjour and the UDP beacon, fed the fixtures a real network would deliver.
@Suite struct DiscoveryTests {
    @Test func plexBonjourRecord() {
        let server = Discovery.parseBonjour(name: "plex._plexmediasvr._tcp.local.", txt: ["name": "Living room", "machineIdentifier": "abc123", "version": "1.41.0"],
                                            host: "192.168.1.20", port: 32400)
        #expect(server?.kind == .plex && server?.name == "Living room" && server?.identifier == "abc123")
        #expect(server?.endpoint.absoluteString == "http://192.168.1.20:32400" && server?.source == .bonjour)
        #expect(Discovery.parseBonjour(name: "x", txt: [:], host: "", port: 32400) == nil)
    }

    @Test func jellyfinAndEmbyBeacons() {
        let jellyfin = Data(#"{"Address":"http://192.168.1.30:8096","Id":"jf-1","Name":"Jellyfin Server","EndpointAddress":null}"#.utf8)
        let emby = Data(#"{"Address":"http://192.168.1.31:8096","Id":"emby-1","Name":"Emby Server"}"#.utf8)
        let j = Discovery.parseBeacon(jellyfin, from: "192.168.1.30")
        let e = Discovery.parseBeacon(emby, from: "192.168.1.31")
        #expect(j?.kind == .jellyfin && j?.identifier == "jf-1" && j?.endpoint.absoluteString == "http://192.168.1.30:8096" && j?.source == .udpBeacon)
        #expect(e?.kind == .emby && e?.name == "Emby Server")
        #expect(Discovery.parseBeacon(Data("not json".utf8), from: "h") == nil)
        #expect(Discovery.parseBeacon(Data(#"{"Address":"nope"}"#.utf8), from: "h") == nil)
    }
}
