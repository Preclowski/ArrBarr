import Testing
import Foundation
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

    @Test("Each server gets its documented auth header")
    func authHeaders() {
        #expect(MediaServerKind.plex.authHeaders(token: "T")["X-Plex-Token"] == "T")
        #expect(MediaServerKind.emby.authHeaders(token: "T")["X-Emby-Token"] == "T")
        #expect(MediaServerKind.jellyfin.authHeaders(token: "T")["Authorization"]
                == "MediaBrowser Token=\"T\"")
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

@Suite("MediaServerPosterAccess")
struct MediaServerPosterAccessTests {

    private let plex = MediaServerConfig(enabled: true, kind: .plex,
                                         baseURL: "http://nas:32400", token: "sekret")
    private let jellyfin = MediaServerConfig(enabled: true, kind: .jellyfin,
                                             baseURL: "http://nas:8096", token: "sekret")

    @Test("Only the connected server's own URLs are recognised")
    func ownership() {
        #expect(MediaServerPosterAccess.owns(URL(string: "http://nas:32400/library/metadata/1/thumb/2")!, config: plex))
        // Different port — a Jellyfin on the same box is a different server.
        #expect(!MediaServerPosterAccess.owns(URL(string: "http://nas:8096/x")!, config: plex))
        #expect(!MediaServerPosterAccess.owns(URL(string: "https://nas:32400/x")!, config: plex))
        #expect(!MediaServerPosterAccess.owns(URL(string: "https://image.tmdb.org/t/p/w500/x.jpg")!, config: plex))
    }

    @Test("The token travels as a header, never in the URL")
    func tokenIsAHeaderOnly() {
        let access = MediaServerPosterAccess(config: plex)
        let mine = URL(string: "http://nas:32400/library/metadata/1/thumb/2")!
        #expect(access.headers(for: mine)["X-Plex-Token"] == "sekret")
        // The resolved URL is persisted and hashed into cache keys, so the
        // token must not appear anywhere in it.
        #expect(!mine.absoluteString.contains("sekret"))
        #expect(access.sizedURL(for: mine, tier: .icon)?.absoluteString.contains("sekret") != true)
    }

    @Test("Someone else's poster never carries our token")
    func noTokenLeakToOtherHosts() {
        let access = MediaServerPosterAccess(config: plex)
        #expect(access.headers(for: URL(string: "https://image.tmdb.org/t/p/w500/x.jpg")!).isEmpty)
    }

    @Test("Plex resizes through the transcoder, carrying the original path")
    func plexSizing() throws {
        let url = URL(string: "http://nas:32400/library/metadata/1/thumb/1690")!
        let sized = try #require(MediaServerPosterAccess.sizedURL(for: url, tier: .icon, config: plex))
        let items = try #require(URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(sized.path == "/photo/:/transcode")
        #expect(items.first { $0.name == "width" }?.value == "288")
        #expect(items.first { $0.name == "url" }?.value == "/library/metadata/1/thumb/1690")
        #expect(items.first { $0.name == "upscale" }?.value == "0")
    }

    @Test("Jellyfin and Emby take a maxWidth, keeping the tag they already carry")
    func jellyfinSizing() throws {
        let url = URL(string: "http://nas:8096/Items/abc/Images/Primary?tag=t1")!
        let sized = try #require(MediaServerPosterAccess.sizedURL(for: url, tier: .card, config: jellyfin))
        let items = try #require(URLComponents(url: sized, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "maxWidth" }?.value == "1200")
        #expect(items.first { $0.name == "tag" }?.value == "t1")
    }

    @Test("The lightbox tier asks for no resizing at all")
    func fullTierStaysOriginal() {
        // `.full` backs the pinch-zoom sheet, which goes to 5× — the one place
        // that must get whatever the server has.
        #expect(PosterTier.full.maxPixelSize == nil)
        for config in [plex, jellyfin] {
            let url = URL(string: "\(config.baseURL)/Items/abc/Images/Primary")!
            #expect(MediaServerPosterAccess.sizedURL(for: url, tier: .full, config: config) == nil)
        }
    }

    @Test("Foreign hosts are left to the CDN variant logic")
    func foreignHostsUnsized() {
        let tmdb = URL(string: "https://image.tmdb.org/t/p/original/x.jpg")!
        #expect(MediaServerPosterAccess.sizedURL(for: tmdb, tier: .icon, config: plex) == nil)
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
