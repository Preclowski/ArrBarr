import Testing
@testable import ArrCore

/// qBittorrent, Transmission, Deluge and rTorrent authenticate with a username
/// and password — they have no API key at all. Gating them on `isVisible`
/// (which requires one) made the gateway register them as disabled, so every
/// call came back "not configured" however well Settings was filled in.
@Suite("Download client usability")
struct DownloadClientUsabilityTests {

    private func config(apiKey: String = "") -> ServiceConfig {
        ServiceConfig(enabled: true, baseURL: "http://127.0.0.1:8080/",
                      apiKey: apiKey, username: "admin", password: "pw")
    }

    @Test("A password-only download client is usable without an API key")
    func passwordClientsNeedNoKey() {
        for kind: ServiceKind in [.qbittorrent, .transmission, .deluge, .rtorrent] {
            #expect(config().isUsable(as: kind), "\(kind.rawValue) should be usable")
            #expect(!config().isVisible)   // the gate that used to be applied
        }
    }

    @Test("Key-based services still need their key")
    func keyedServicesStillNeedTheKey() {
        for kind: ServiceKind in [.radarr, .sonarr, .lidarr, .whisparr, .sabnzbd] {
            #expect(!config().isUsable(as: kind), "\(kind.rawValue) must not be usable without a key")
            #expect(config(apiKey: "k").isUsable(as: kind))
        }
    }

    @Test("A disabled or URL-less client is never usable")
    func disabledIsNeverUsable() {
        #expect(!ServiceConfig(enabled: false, baseURL: "http://127.0.0.1:8080/",
                               apiKey: "", username: "a", password: "b").isUsable(as: .qbittorrent))
        #expect(!ServiceConfig(enabled: true, baseURL: "",
                               apiKey: "", username: "a", password: "b").isUsable(as: .qbittorrent))
    }
}
