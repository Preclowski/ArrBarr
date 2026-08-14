import Testing
import Foundation
@testable import ArrCore

@Suite("MediaServerGuidParser")
struct MediaServerGuidParserTests {

    @Test("Modern Plex guids parse to their provider keys")
    func modernGuids() {
        #expect(MediaServerGuidParser.key(from: "tmdb://157336") == .tmdb(157336))
        #expect(MediaServerGuidParser.key(from: "tvdb://121361") == .tvdb(121361))
        #expect(MediaServerGuidParser.key(from: "imdb://tt0816692") == .imdb("tt0816692"))
    }

    @Test("Legacy agent guids parse too")
    func legacyAgentGuids() {
        // Old agent-based libraries never got the `Guid` array, so these are
        // the only ids those items carry.
        #expect(MediaServerGuidParser.key(from: "com.plexapp.agents.themoviedb://157336?lang=en") == .tmdb(157336))
        #expect(MediaServerGuidParser.key(from: "com.plexapp.agents.imdb://tt0816692?lang=en") == .imdb("tt0816692"))
    }

    @Test("TVDB guids drop the season/episode path components")
    func tvdbWithEpisodePath() {
        #expect(MediaServerGuidParser.key(from: "com.plexapp.agents.thetvdb://121361/2/1?lang=en") == .tvdb(121361))
    }

    @Test("Unknown schemes and malformed guids yield nothing")
    func rejects() {
        #expect(MediaServerGuidParser.key(from: "plex://movie/5d776be17a53e9001e732ab9") == nil)
        #expect(MediaServerGuidParser.key(from: "tmdb://") == nil)
        #expect(MediaServerGuidParser.key(from: "157336") == nil)
        // An imdb id that isn't a "tt" id is not an imdb id.
        #expect(MediaServerGuidParser.key(from: "imdb://12345") == nil)
    }

    @Test("Jellyfin / Emby ProviderIds map case-insensitively")
    func providerIds() {
        let keys = MediaServerGuidParser.keys(fromProviderIds: [
            "Tmdb": "157336",
            "IMDB": "TT0816692",
            "tvdb": "121361",
            "MusicBrainzAlbum": "abc",
            "Tmdb2": "",
        ])
        #expect(Set(keys) == Set([.tmdb(157336), .imdb("tt0816692"), .tvdb(121361)]))
    }

    @Test("Blank and non-numeric provider values are dropped")
    func providerIdsRejects() {
        let keys = MediaServerGuidParser.keys(fromProviderIds: [
            "Tmdb": "  ",
            "Tvdb": "not-a-number",
            "Imdb": "12345",
        ])
        #expect(keys.isEmpty)
    }
}

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

@Suite("DiscoverLLMPrompt watch history")
struct DiscoverPromptWatchHistoryTests {

    @Test("Watched titles appear as both a taste signal and an exclusion")
    func watchedInPrompt() {
        let prompt = DiscoverLLMPrompt.build(
            mood: "something tense", count: 5, exclude: [],
            kindHint: .movie, watched: ["Heat (1995)", "Sicario (2015)"]
        )
        #expect(prompt.contains("Heat (1995)"))
        #expect(prompt.contains("Sicario (2015)"))
        #expect(prompt.lowercased().contains("recently watched"))
    }

    @Test("No watch history leaves the prompt as it was")
    func noWatchHistory() {
        let withHistory = DiscoverLLMPrompt.build(mood: "m", count: 5, exclude: [], watched: [])
        let without = DiscoverLLMPrompt.build(mood: "m", count: 5, exclude: [])
        #expect(withHistory == without)
    }

    @Test("The watched list is capped so it can't dominate the prompt")
    func watchedCapped() {
        let many = (1...100).map { "Title \($0)" }
        let prompt = DiscoverLLMPrompt.build(mood: "m", count: 5, exclude: [], watched: many)
        #expect(prompt.contains("Title 40"))
        #expect(!prompt.contains("Title 41"))
    }
}

@Suite("Cached poster resolution")
struct CachedPosterResolutionTests {

    private func metadata(keys: [MediaServerExternalKey]) -> TitleMetadataStore.Metadata {
        TitleMetadataStore.Metadata(
            title: "Inception", year: 2010,
            posterURL: URL(string: "http://radarr:7878/MediaCover/1/poster.jpg"),
            posterRequiresAuth: true,
            mediaServerKeys: keys.map(\.rawKey)
        )
    }

    @Test("External keys survive a round trip through their stored text form")
    func rawKeyRoundTrip() {
        let keys: [MediaServerExternalKey] = [.tmdb(157336), .tvdb(121361), .imdb("tt0816692")]
        for key in keys {
            #expect(MediaServerExternalKey(rawKey: key.rawKey) == key)
        }
        #expect(MediaServerExternalKey(rawKey: "tmdb:") == nil)
        #expect(MediaServerExternalKey(rawKey: "nope:1") == nil)
        #expect(MediaServerExternalKey(rawKey: "157336") == nil)
    }

    @Test("A cached record keeps the arr's artwork when no server holds the title")
    func noOverrideWithoutIndex() {
        // The bug this guards: the override used to be baked in at WRITE time,
        // so an entry cached before a media server was connected kept the arr's
        // poster for the store's whole retention while detail views showed the
        // server's.
        let record = metadata(keys: [.tmdb(157336)])
        let resolved = record.applyingMediaServerArtwork()
        #expect(resolved.posterURL == record.posterURL)
        #expect(resolved.posterRequiresAuth)
    }

    @Test("A record with no external ids is returned untouched")
    func noKeysNoOverride() {
        let record = metadata(keys: [])
        #expect(record.applyingMediaServerArtwork() == record)
    }

    @Test("Records written before the ids existed still decode")
    func decodesLegacyRecord() throws {
        // `mediaServerKeys` is optional precisely so an existing
        // title-metadata.json survives the upgrade.
        let json = #"{"title":"Inception","posterRequiresAuth":false}"#
        let decoded = try JSONDecoder().decode(
            TitleMetadataStore.Metadata.self, from: Data(json.utf8))
        #expect(decoded.title == "Inception")
        #expect(decoded.mediaServerKeys == nil)
        #expect(decoded.applyingMediaServerArtwork() == decoded)
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
        #expect(!MonitoredService.mediaServer.isArr)
        #expect(!MonitoredService.mediaServer.isDownloadClient)
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
