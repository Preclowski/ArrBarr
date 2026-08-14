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

    @Test("Only Jellyfin and Emby need a resolved user id")
    func userIdRequirement() {
        #expect(!MediaServerKind.plex.requiresUserId)
        #expect(MediaServerKind.jellyfin.requiresUserId)
        #expect(MediaServerKind.emby.requiresUserId)
    }
}

@Suite("MediaServerIndex")
struct MediaServerIndexTests {

    private func entry(itemId: String, keys: [MediaServerExternalKey],
                       poster: String?, watched: Bool = false) -> MediaServerEntry {
        MediaServerEntry(
            itemId: itemId, kind: .movie, title: "T", year: 2010,
            posterURL: poster.flatMap(URL.init(string:)),
            externalKeys: keys, watched: watched, playCount: watched ? 1 : 0,
            lastPlayed: nil
        )
    }

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
