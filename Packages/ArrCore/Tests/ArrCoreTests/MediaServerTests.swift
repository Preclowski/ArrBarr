import Testing
import Foundation
import MediaKit
@testable import ArrCore

@Suite("MediaServerConfig")
struct MediaServerConfigTests {

    @Test("A config needs enabled + URL + token to be usable")
    func isConfigured() {
        var cfg = MediaServerConfig(enabled: true, kind: .plex,
                                    baseURL: "http://nas:32400", token: "abc")
        #expect(cfg.isConfigured)

        cfg.enabled = false
        #expect(!cfg.isConfigured)

        cfg.enabled = true
        cfg.token = ""
        #expect(!cfg.isConfigured)

        cfg.token = "abc"
        cfg.baseURL = "nas:32400"   // no scheme
        #expect(!cfg.isConfigured)

        cfg.baseURL = "ftp://nas"
        #expect(!cfg.isConfigured)
    }
}

@Suite("MediaServerIndex")
struct MediaServerIndexTests {

    @Test("An empty index returns no poster and no watch state")
    func emptyIndexIsInert() {
        let index = MediaServerIndex()
        #expect(index.posterURL(for: [.tmdb(1)]) == nil)
        #expect(!index.isWatched([.tmdb(1)]))
        #expect(index.indexedTitleCount == 0)
    }

    @Test("Arr poster resolution falls back when the index has no match")
    func posterFallback() {
        // The whole safety property of the override: no media server, or a
        // title it doesn't hold, must leave the arr's artwork untouched.
        let images = [ArrImage(coverType: "poster", url: "/MediaCover/1/poster.jpg",
                               remoteUrl: "https://image.tmdb.org/p/w500/x.jpg")]
        let (url, auth) = images.posterURL(baseURL: "http://radarr:7878",
                                           mediaServerKeys: [.tmdb(999)])
        #expect(url?.absoluteString == "https://image.tmdb.org/p/w500/x.jpg")
        #expect(auth == false)
    }

    @Test("No keys at all is the same as no match")
    func posterFallbackWithoutKeys() {
        let images = [ArrImage(coverType: "poster", url: nil,
                               remoteUrl: "https://image.tmdb.org/p/w500/x.jpg")]
        let (url, _) = images.posterURL(baseURL: "http://radarr:7878", mediaServerKeys: [])
        #expect(url?.absoluteString == "https://image.tmdb.org/p/w500/x.jpg")
    }
}

@Suite("Media server artwork")
struct MediaServerArtworkTests {

    private let plex = ArtworkReference(url: URL(string: "http://nas:32400/library/metadata/1/thumb/1690")!,
                                        headers: ["X-Plex-Token": .credential(InstanceID(.plex))],
                                        sizing: .plexTranscode(photoPath: "/library/metadata/1/thumb/1690"), kind: .poster)
    private let jellyfin = ArtworkReference(url: URL(string: "http://nas:8096/jellyfin/Items/abc/Images/Primary")!,
                                            headers: ["Authorization": .credential(InstanceID(.jellyfin))],
                                            sizing: .jellyfinFill(itemID: "abc", tag: "t1"), kind: .poster)

    @Test("Plex resizes through the transcoder, carrying the original path")
    func plexSizing() throws {
        let sized = try #require(PosterStore.sourceURL(for: plex.url, tier: .icon, artwork: plex))
        let items = try #require(URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(sized.path == "/photo/:/transcode")
        #expect(items.first { $0.name == "url" }?.value == "/library/metadata/1/thumb/1690")
        #expect(items.first { $0.name == "upscale" }?.value == "0")
    }

    @Test("Jellyfin keeps its reverse-proxy prefix and adds maxWidth and tag")
    func jellyfinSizing() throws {
        let sized = try #require(PosterStore.sourceURL(for: jellyfin.url, tier: .card, artwork: jellyfin))
        let items = try #require(URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(sized.path == "/jellyfin/Items/abc/Images/Primary")
        #expect(items.first { $0.name == "maxWidth" } != nil)
        #expect(items.first { $0.name == "tag" }?.value == "t1")
    }

    @Test("The lightbox tier and URLs without a reference are fetched as stored")
    func unsized() {
        #expect(PosterStore.sourceURL(for: plex.url, tier: .full, artwork: plex) == nil)
        #expect(PosterStore.sourceURL(for: URL(string: "http://nas:32400/x")!, tier: .icon) == nil)
    }
}

@Suite("Media server health monitoring")
struct MediaServerMonitoringTests {

    @Test("The media server is a monitored service and needs its own probe")
    func isMonitored() {
        #expect(MonitoredService.allCases.contains(.mediaServer))
        // Nothing in the queue refresh touches it, so it can't ride along on
        // the arr fetch the way Radarr/Sonarr do.
        #expect(MonitoredService.probeTargets.contains(.mediaServer))
        #expect(MonitoredService.mediaServer.serviceKind == nil)
    }

    @Test("Every media server ships a brand icon")
    func brandIcons() {
        for kind in MediaServerKind.allCases {
            #expect(kind.brandIconName == kind.rawValue)
        }
    }
}

@Suite("Media server tool gating")
struct MediaServerToolGatingTests {

    @Test("Media-server tools are advertised only when a server is connected")
    func catalogGating() {
        let without = ChatToolCatalog.tools(includeMediaServer: false).map(\.name)
        #expect(!without.contains("media_server_watch_history"))

        let with = ChatToolCatalog.tools(includeMediaServer: true).map(\.name)
        #expect(with.contains("media_server_watch_history"))
        #expect(with.contains("media_server_now_playing"))
        #expect(with.contains("media_server_scan_library"))
    }

    @Test("Reads run unconfirmed; the scan is gated")
    func whitelist() {
        #expect(!MCPToolWhitelist.isDestructive("media_server_watch_history"))
        #expect(!MCPToolWhitelist.isDestructive("media_server_now_playing"))
        // Queues work on someone's server — the user gets a say.
        #expect(MCPToolWhitelist.isDestructive("media_server_scan_library"))
    }

    @Test("Every media-server tool is listed in the settings directory")
    func directoryCoverage() {
        let directory = Set(ChatToolCatalog.toolDirectory.map(\.name))
        for name in ["media_server_watch_history", "media_server_now_playing", "media_server_scan_library"] {
            #expect(directory.contains(name))
        }
    }
}
