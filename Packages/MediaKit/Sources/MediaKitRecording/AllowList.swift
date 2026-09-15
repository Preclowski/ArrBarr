import Foundation
import MediaKit

/// The prompt's section-5 table as code: reads only, one login per run, `/release` never.
public struct AllowList: Sendable {
    public struct Rule: Sendable {
        public let kind: InstanceKind
        public let method: String
        public let pathPrefix: String
        public let rpcMethod: String?
        public let query: [String: String]?

        public init(kind: InstanceKind, method: String = "GET", pathPrefix: String, rpcMethod: String? = nil, query: [String: String]? = nil) {
            self.kind = kind; self.method = method; self.pathPrefix = pathPrefix; self.rpcMethod = rpcMethod; self.query = query
        }
    }

    public let rules: [Rule]
    public init(rules: [Rule]) { self.rules = rules }

    public static let section5: AllowList = {
        var rules: [Rule] = []
        let servarrReads = ["system/status", "health", "diskspace", "queue", "history", "calendar", "movie", "series", "artist", "album",
                            "episode", "episodefile", "moviefile", "trackfile", "qualityprofile", "rootfolder", "metadataprofile",
                            "customformat", "downloadclient", "command", "credit", "alttitle", "tag", "queue/status", "wanted"]
        for (kind, api) in [(InstanceKind.radarr, "/api/v3/"), (.sonarr, "/api/v3/"), (.whisparr, "/api/v3/"), (.lidarr, "/api/v1/")] {
            for read in servarrReads { rules.append(Rule(kind: kind, pathPrefix: api + read)) }
            rules.append(Rule(kind: kind, method: "POST", pathPrefix: "/signalr/messages/negotiate"))
            rules.append(Rule(kind: kind, pathPrefix: "/signalr/messages"))
        }
        rules.append(Rule(kind: .lidarr, pathPrefix: "/api/v1/track"))
        rules.append(Rule(kind: .lidarr, pathPrefix: "/api/v1/search"))
        rules.append(Rule(kind: .qbittorrent, method: "POST", pathPrefix: "/api/v2/auth/login"))
        for read in ["app/version", "app/preferences", "app/webapiVersion", "torrents/info"] { rules.append(Rule(kind: .qbittorrent, pathPrefix: "/api/v2/" + read)) }
        for rpc in ["session-get", "torrent-get"] { rules.append(Rule(kind: .transmission, method: "POST", pathPrefix: "/transmission/rpc", rpcMethod: rpc)) }
        for rpc in ["auth.login", "daemon.info", "core.get_torrents_status", "core.get_config", "web.connected", "auth.check_session"] {
            rules.append(Rule(kind: .deluge, method: "POST", pathPrefix: "/json", rpcMethod: rpc))
        }
        for rpc in ["system.client_version", "d.multicall2", "system.listMethods"] { rules.append(Rule(kind: .rtorrent, method: "POST", pathPrefix: "/", rpcMethod: rpc)) }
        for mode in ["version", "queue", "history"] { rules.append(Rule(kind: .sabnzbd, pathPrefix: "/api", query: ["mode": mode])) }
        for rpc in ["version", "listgroups", "history", "status"] { rules.append(Rule(kind: .nzbget, method: "POST", pathPrefix: "/jsonrpc", rpcMethod: rpc)) }
        for path in ["/identity", "/library/sections", "/status/sessions", "/library/metadata", "/status/sessions/history"] { rules.append(Rule(kind: .plex, pathPrefix: path)) }
        for kind in [InstanceKind.jellyfin, .emby] {
            for path in ["/System/Info", "/Users", "/Items", "/Sessions"] { rules.append(Rule(kind: kind, pathPrefix: path)) }
        }
        rules.append(Rule(kind: .tmdb, pathPrefix: "/3/"))
        return AllowList(rules: rules)
    }()

    public func permits(_ request: HTTPRequest, kind: InstanceKind) -> Bool {
        let path = request.url.path
        if kind.family == .servarr, path.contains("/release") { return false }
        if kind == .tmdb, path.hasPrefix("/3/authentication") || path.hasPrefix("/3/account") { return request.method == "GET" && !path.hasPrefix("/3/authentication") }
        if kind == .plex, path.hasSuffix("/refresh") || path.hasSuffix("/emptyTrash") || path.contains("/photo/") { return false }
        if kind == .jellyfin || kind == .emby, path.hasPrefix("/Library/Refresh") || path.contains("/Playing") { return false }
        let query = Dictionary((URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if kind == .sabnzbd, query["name"] == "delete" { return false }
        return rules.contains { rule in
            guard rule.kind == kind, rule.method == request.method else { return false }
            guard path.hasPrefix(rule.pathPrefix) || (rule.pathPrefix.hasSuffix("/") && path == String(rule.pathPrefix.dropLast())) else { return false }
            if let rpc = rule.rpcMethod, rpc != request.rpcMethod { return false }
            if let required = rule.query { for (k, v) in required where query[k] != v { return false } }
            return true
        }
    }
}
