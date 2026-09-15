import Foundation
import Testing
@testable import ArrCore

// Phase 0 of the MediaKit rewrite: record (A) the requests today's ArrCore
// clients emit per operation and (B) response fixtures from the owner's live
// services, reads only.
//
// Everything here is inert unless ARRBARR_RECORD=1 is in the environment:
// `RecordingProtocol.canInit` answers false, and the driver test returns
// immediately. The normal suite therefore never sees it (other suites in this
// package register greedy URLProtocol stubs of their own — this must not add
// another one to the pile).
//
// The allow-list below is the enforcement, not a convention: a request that
// does not match a rule is never forwarded to a real host; it is answered
// locally with a synthetic response so the client code completes and the
// request shape is still captured.

// MARK: - Locations

private enum RecPaths {
    static let rawRoot =
        "/private/tmp/claude-501/-Users-konrad-Workspace-ai-ArrBarr-ArrBarr/ea5efd3f-1646-4a61-9786-d876d2be1a39/scratchpad/recordings"
    static let repoRoot = "/Users/konrad/Workspace/ai/ArrBarr/ArrBarr"
    static let baselineFile = repoRoot + "/docs/superpowers/baseline/2026-09-15-golden-requests.json"
    static let fixturesRoot = repoRoot + "/Packages/MediaKit/Fixtures"
    static let reportFile = rawRoot + "/run-report.json"
    static let recordedAt = "2026-09-15"
}

// MARK: - Stored config (mirrors ConfigStore's decoding)

/// The app is sandboxed, so its App Group suite lives inside the container and
/// `UserDefaults(suiteName:)` from a plain test process would not find it. Read
/// the plist directly and hand the dictionary to ConfigStore's own decoders —
/// the storage format stays known only to ConfigStore.
private struct StoredConfig {
    let storage: [String: Any]

    init() {
        let path = NSString(
            string: "~/Library/Containers/pl.incred.ArrBarr/Data/Library/Preferences/group.pl.incred.ArrBarr.plist"
        ).expandingTildeInPath
        storage = (NSDictionary(contentsOfFile: path) as? [String: Any]) ?? [:]
    }

    func service(_ kind: ServiceKind) -> ServiceConfig {
        var cfg = ConfigStore.decodeServiceConfig(kind, from: storage)
        if let key = storage[SecretKey.apiKey(for: kind).plaintextDefaultsKey] as? String, !key.isEmpty {
            cfg.apiKey = key
        }
        if let pw = storage[SecretKey.password(for: kind).plaintextDefaultsKey] as? String, !pw.isEmpty {
            cfg.password = pw
        }
        return cfg
    }

    var mediaServer: MediaServerConfig {
        var cfg = ConfigStore.decodeMediaServerConfig(from: storage)
        if let token = storage[SecretKey.mediaServerToken.plaintextDefaultsKey] as? String, !token.isEmpty {
            cfg.token = token
        }
        return cfg
    }

    var tmdbKey: String {
        (storage[SecretKey.tmdbKey.plaintextDefaultsKey] as? String) ?? ""
    }

    /// Every secret value this run could possibly leak, for the scrub pass.
    var knownSecrets: [String] {
        var out: [String] = []
        for kind in ServiceKind.allCases {
            let cfg = service(kind)
            out.append(cfg.apiKey)
            out.append(cfg.password)
        }
        out.append(mediaServer.token)
        out.append(tmdbKey)
        if let openAI = storage[SecretKey.openAIKey.plaintextDefaultsKey] as? String { out.append(openAI) }
        return out.filter { $0.count >= 8 }
    }
}

// MARK: - Allow-list

/// One permitted live call. `client` is the service family the rule belongs to;
/// `method` the HTTP verb; `matches` the path/query/body predicate.
private struct AllowRule {
    let client: String
    let method: String
    let label: String
    let matches: (URL, String?) -> Bool
}

private enum ArrAllow {
    /// First path segment after `/api/vN` that may be GET'd. `/release` is
    /// deliberately absent — a GET there fans a search out to every indexer.
    static let segments: Set<String> = [
        "health", "diskspace", "queue", "history", "calendar",
        "movie", "series", "artist", "album", "episode",
        "episodefile", "moviefile", "trackfile",
        "qualityprofile", "rootfolder", "metadataprofile",
        "customformat", "downloadclient", "command",
        "credit", "alttitle",
    ]

    /// Owner-approved Lidarr-only reads. `/search` is Lidarr's metadata-lookup
    /// endpoint (the one its own UI uses for text terms) — it queries the
    /// metadata server, NOT the indexers, so it is not the `/release` fan-out
    /// the segment list above deliberately excludes.
    static let lidarrSegments: Set<String> = ["track", "search"]
}

// MARK: - Recorder

private struct GoldenEntry: Codable {
    var client: String
    var operation: String
    var method: String
    var path: String
    var query_keys: [String]
    var header_names: [String]
    var body: String?
    var allowed: Bool
    var intercept_reason: String?
    var count: Int
}

private struct RecordedResponse {
    var client: String
    var operation: String
    var path: String
    var status: Int
    var headers: [String: String]
    var data: Data
}

private final class Recorder: @unchecked Sendable {
    static let shared = Recorder()

    private let lock = NSLock()

    // Live targets. A request whose host is not in here is NEVER forwarded,
    // whatever the rule table says.
    private var liveHosts: [String: String] = [:]      // host -> client key
    private var arrBase: [String: String] = [:]        // client key -> "/api/v3"
    private var qbitLoginCount = 0

    private var currentClient = "unknown"
    private var currentOperation = "unknown"

    private(set) var entries: [String: GoldenEntry] = [:]   // dedup key -> entry
    private(set) var responses: [RecordedResponse] = []
    private(set) var notes: [String] = []
    private var rawCounter: [String: Int] = [:]

    // Anonymization inputs, collected during the run.
    private var rootPaths: [String: String] = [:]      // real path -> "/data/<kind>"
    private var secrets: [String] = []
    private var hostAliases: [String: String] = [:]    // real host -> "radarr.local"

    func configure(liveHosts: [String: String], arrBase: [String: String],
                   hostAliases: [String: String], secrets: [String]) {
        lock.lock(); defer { lock.unlock() }
        self.liveHosts = liveHosts
        self.arrBase = arrBase
        self.hostAliases = hostAliases
        self.secrets = secrets.filter { !$0.isEmpty }
    }

    func addRootPath(_ path: String, kind: String) {
        lock.lock(); defer { lock.unlock() }
        guard path.count > 2 else { return }
        rootPaths[path] = "/data/\(kind)"
    }

    func begin(_ client: String, _ operation: String) {
        lock.lock(); defer { lock.unlock() }
        currentClient = client
        currentOperation = operation
    }

    func note(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        notes.append(text)
    }

    var context: (client: String, operation: String) {
        lock.lock(); defer { lock.unlock() }
        return (currentClient, currentOperation)
    }

    func clientKey(forHost host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return liveHosts[host]
    }

    func apiBase(forClient key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return arrBase[key] ?? "/api/v3"
    }

    /// qBittorrent bans an IP after repeated failed logins — one handshake per
    /// run, ever.
    func allowQbitLogin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard qbitLoginCount == 0 else { return false }
        qbitLoginCount += 1
        return true
    }

    func log(_ entry: GoldenEntry) {
        lock.lock(); defer { lock.unlock() }
        let key = "\(entry.client)|\(entry.operation)|\(entry.method)|\(entry.path)|\(entry.query_keys.joined(separator: ","))"
        if var existing = entries[key] {
            existing.count += 1
            entries[key] = existing
        } else {
            entries[key] = entry
        }
    }

    func store(_ response: RecordedResponse) {
        lock.lock()
        responses.append(response)
        let slug = Scrub.slug("\(response.operation)-\(response.path)")
        let n = (rawCounter[slug] ?? 0) + 1
        rawCounter[slug] = n
        let dir = "\(RecPaths.rawRoot)/\(response.client)"
        let name = n == 1 ? slug : "\(slug)-\(n)"
        let headers = response.headers
        let status = response.status
        let path = response.path
        let data = response.data
        lock.unlock()

        // Raw, unscrubbed — scratchpad only, never the repo.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).json"))
        let meta: [String: Any] = ["status": status, "headers": headers, "path": path]
        if let metaData = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? metaData.write(to: URL(fileURLWithPath: "\(dir)/\(name).meta.json"))
        }
    }

    var scrubInputs: (secrets: [String], hosts: [String: String], roots: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        return (secrets, hostAliases, rootPaths)
    }
}

// MARK: - Scrubbing / anonymization

private enum Scrub {
    /// JSON field names whose value is a secret.
    static let secretKey = try! NSRegularExpression(
        pattern: "(api[_-]?key|password|token|secret|passphrase)", options: [.caseInsensitive])
    /// Field names carrying a tracker/announce URL — a private tracker's
    /// passkey travels in exactly those, and this repo is public.
    static let trackerKey = try! NSRegularExpression(
        pattern: "^(magnet_uri|magnetUrl|tracker|trackers|announce|announce_list|comment|created_by|download_url|downloadUrl|infoUrl|nzbInfoUrl)$",
        options: [.caseInsensitive])
    /// Field names carrying a filesystem location on the owner's server.
    static let pathKey = try! NSRegularExpression(
        pattern: "^(path|save_path|content_path|download_path|rootFolderPath|folderName|sourcePath|outputPath|location|storage|file)$",
        options: [.caseInsensitive])
    /// Field names that identify the owner rather than the media.
    static let identityKey = try! NSRegularExpression(
        pattern: "^(username|userName|user|friendlyName|machineIdentifier|clientIdentifier|deviceIdentifier|email|accountID|accountId|userId|UserId|UserName|ServerId|ServerName|DeviceId|DeviceName|thumb_user)$",
        options: [.caseInsensitive])

    static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        var out = String(mapped)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(out.prefix(80))
    }

    /// Text-level pass: known secret values, then hostnames, then root folders.
    static func text(_ s: String) -> String {
        let (secrets, hosts, roots) = Recorder.shared.scrubInputs
        var out = s
        for secret in secrets where !secret.isEmpty {
            out = out.replacingOccurrences(of: secret, with: "<redacted>")
        }
        for (host, alias) in hosts.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: host, with: alias)
        }
        // Anything left on the same parent domain.
        for suffix in parentDomains(of: Array(hosts.keys)) {
            out = out.replacingOccurrences(of: suffix, with: "local")
        }
        for (real, replacement) in roots.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: real, with: replacement)
        }
        return out
    }

    static func parentDomains(of hosts: [String]) -> [String] {
        var out: Set<String> = []
        for host in hosts {
            let parts = host.split(separator: ".")
            if parts.count >= 2 { out.insert(parts.suffix(2).joined(separator: ".")) }
        }
        return Array(out).sorted { $0.count > $1.count }
    }

    /// Recursive JSON scrub. Types are preserved: a redacted string stays a
    /// string, a redacted number becomes 0 — a fixture whose types shifted
    /// would fail the very decoders it exists to test.
    static func json(_ value: Any, client: String = "") -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if matches(secretKey, k) || matches(trackerKey, k) {
                    out[k] = (v is String) ? "<redacted>" : (v is NSNull ? NSNull() : 0)
                } else if matches(identityKey, k) {
                    out[k] = (v is String) ? "user" : (v is NSNull ? NSNull() : 0)
                } else if matches(pathKey, k), let s = v as? String {
                    out[k] = serverPath(text(s), client: client)
                } else {
                    out[k] = json(v, client: client)
                }
            }
            return out
        }
        if let arr = value as? [Any] { return arr.map { json($0, client: client) } }
        if let s = value as? String { return text(s) }
        return value
    }

    /// Absolute locations on the owner's server keep only their last two
    /// components (enough to keep a path parser honest) under `/data/<kind>`.
    /// Anything already rewritten by the root-folder map starts with `/data/`
    /// and is left alone.
    static func serverPath(_ value: String, client: String) -> String {
        guard value.hasPrefix("/"), !value.hasPrefix("/data/") else { return value }
        let parts = value.split(separator: "/").map(String.init)
        let tail = parts.suffix(2).joined(separator: "/")
        let kind = client.isEmpty ? "media" : client
        return tail.isEmpty ? "/data/\(kind)" : "/data/\(kind)/\(tail)"
    }

    /// Whisparr is recorded shape-only: the repo is public.
    static func titlesOnly(_ value: Any, counter: inout Int) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                let lower = k.lowercased()
                if (lower == "title" || lower == "sorttitle" || lower == "cleantitle"
                    || lower == "originaltitle" || lower == "overview"), v is String {
                    counter += 1
                    out[k] = lower == "overview" ? "Overview 1" : "Title \(counter)"
                } else {
                    out[k] = titlesOnly(v, counter: &counter)
                }
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.prefix(1).map { titlesOnly($0, counter: &counter) }
        }
        return value
    }
}

// MARK: - Truncation

private enum Truncate {
    static let maxElements = 5

    /// Greedy set-cover over key names: prefer elements that together mention
    /// the most distinct fields, so a movie with a file and one without both
    /// survive instead of five copies of the same shape.
    static func representative(_ array: [Any]) -> [Any] {
        guard array.count > maxElements else { return array }
        var remaining = Array(array.enumerated())
        var covered: Set<String> = []
        var picked: [Any] = []
        while picked.count < maxElements, !remaining.isEmpty {
            var bestIndex = 0
            var bestGain = -1
            for (i, candidate) in remaining.enumerated() {
                let gain = keys(of: candidate.element).subtracting(covered).count
                if gain > bestGain { bestGain = gain; bestIndex = i }
            }
            let chosen = remaining.remove(at: bestIndex)
            covered.formUnion(keys(of: chosen.element))
            picked.append(chosen.element)
        }
        return picked
    }

    private static func keys(of value: Any, prefix: String = "") -> Set<String> {
        guard let dict = value as? [String: Any] else { return [] }
        var out: Set<String> = []
        for (k, v) in dict {
            let path = prefix.isEmpty ? k : "\(prefix).\(k)"
            if v is NSNull { continue }
            out.insert(path)
            if v is [String: Any] { out.formUnion(keys(of: v, prefix: path)) }
            if let arr = v as? [Any], let first = arr.first { out.formUnion(keys(of: first, prefix: path)) }
        }
        return out
    }

    /// Returns the truncated value plus the original count of every top-level
    /// array that was cut.
    static func apply(_ value: Any) -> (value: Any, counts: [String: Int], truncated: Bool) {
        if let arr = value as? [Any] {
            let cut = representative(arr)
            return (cut, ["$": arr.count], cut.count != arr.count)
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            var counts: [String: Int] = [:]
            var truncated = false
            for (k, v) in dict {
                if let arr = v as? [Any] {
                    let cut = representative(arr)
                    out[k] = cut
                    counts[k] = arr.count
                    if cut.count != arr.count { truncated = true }
                } else if let nested = v as? [String: Any] {
                    // Plex/Jellyfin wrap their payload one level down
                    // (MediaContainer / Items), so reach through it.
                    var nestedOut: [String: Any] = [:]
                    for (nk, nv) in nested {
                        if let arr = nv as? [Any] {
                            let cut = representative(arr)
                            nestedOut[nk] = cut
                            counts["\(k).\(nk)"] = arr.count
                            if cut.count != arr.count { truncated = true }
                        } else {
                            nestedOut[nk] = nv
                        }
                    }
                    out[k] = nestedOut
                } else {
                    out[k] = v
                }
            }
            return (out, counts, truncated)
        }
        return (value, [:], false)
    }
}

// MARK: - The interceptor

final class RecordingProtocol: URLProtocol, @unchecked Sendable {

    /// Plain forwarder. `protocolClasses = []` keeps this class out of its own
    /// session, so a forwarded request cannot recurse back through it.
    private static let forwardSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = []
        cfg.httpCookieStorage = HTTPCookieStorage()
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        ProcessInfo.processInfo.environment["ARRBARR_RECORD"] == "1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLProtocol replaces `httpBody` with a stream; drain it back out.
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 8192
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: Allow-list evaluation

    /// The single gate. Returns nil when the request may go out, or a reason
    /// string when it must be answered locally.
    static func refusalReason(_ request: URLRequest, body: Data?) -> String? {
        guard let url = request.url, let host = url.host else { return "no host" }
        guard let kind = Recorder.shared.clientKey(forHost: host) else { return "host not a configured live service" }
        let method = (request.httpMethod ?? "GET").uppercased()
        let path = url.path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let bodyText = body.flatMap { String(data: $0, encoding: .utf8) }

        switch kind {
        case "radarr", "sonarr", "lidarr", "whisparr":
            if method == "POST", path.contains("/signalr/"), path.hasSuffix("negotiate") { return nil }
            guard method == "GET" else { return "arr: only GET and signalr/negotiate are allow-listed" }
            let base = Recorder.shared.apiBase(forClient: kind)
            guard let r = path.range(of: base) else { return "arr: path outside \(base)" }
            let rest = String(path[r.upperBound...])
            let segments = rest.split(separator: "/").map(String.init)
            guard let first = segments.first?.lowercased() else { return "arr: empty path" }
            if first == "system" {
                return segments.count >= 2 && segments[1].lowercased() == "status"
                    ? nil : "arr: only /system/status"
            }
            if ArrAllow.segments.contains(first) { return nil }
            if kind == "lidarr", ArrAllow.lidarrSegments.contains(first) { return nil }
            return "arr: /\(first) not allow-listed"

        case "qbittorrent":
            if method == "POST", path == "/api/v2/auth/login" {
                return Recorder.shared.allowQbitLogin() ? nil : "qbittorrent: one login per run"
            }
            guard method == "GET" else { return "qbittorrent: only GET reads are allow-listed" }
            let allowed = ["/api/v2/app/version", "/api/v2/app/preferences", "/api/v2/torrents/info"]
            return allowed.contains(path) ? nil : "qbittorrent: \(path) not allow-listed"

        case "sabnzbd":
            guard method == "GET" else { return "sabnzbd: only GET is allow-listed" }
            guard path.hasSuffix("/api") || path == "/api" else { return "sabnzbd: only /api" }
            let mode = query.first { $0.name == "mode" }?.value ?? ""
            let name = query.first { $0.name == "name" }?.value
            guard name == nil else { return "sabnzbd: mode=\(mode)&name=\(name ?? "") is an action" }
            return ["version", "queue", "history"].contains(mode)
                ? nil : "sabnzbd: mode=\(mode) not allow-listed"

        case "plex":
            guard method == "GET" else { return "plex: only GET is allow-listed" }
            if path.hasSuffix("/refresh") || path.hasSuffix("/emptyTrash") { return "plex: maintenance write" }
            if path == "/identity" || path == "/library/sections" || path == "/status/sessions" { return nil }
            if path.hasPrefix("/status/sessions/history") { return nil }
            if path.hasPrefix("/library/metadata/") { return nil }
            if path.hasPrefix("/library/sections/"), path.hasSuffix("/all") { return nil }
            return "plex: \(path) not allow-listed"

        case "jellyfin":
            guard method == "GET" else { return "jellyfin: only GET is allow-listed" }
            let allowedPrefixes = ["/System/Info", "/Users", "/Items", "/Sessions"]
            if path.contains("/Refresh") { return "jellyfin: refresh is a write" }
            return allowedPrefixes.contains(where: { path.hasPrefix($0) })
                ? nil : "jellyfin: \(path) not allow-listed"

        case "tmdb":
            guard method == "GET" else { return "tmdb: only GET is allow-listed" }
            if path.hasPrefix("/3/authentication") || path.hasPrefix("/3/account") {
                return "tmdb: authentication/account are excluded"
            }
            return nil

        default:
            _ = bodyText
            return "no rule for \(kind)"
        }
    }

    // MARK: Synthetic answers for refused requests

    private static func synthetic(for request: URLRequest) -> (Data, String) {
        let url = request.url
        let host = url?.host ?? ""
        let kind = Recorder.shared.clientKey(forHost: host) ?? Self.kindGuess(host: host, url: url)
        let method = (request.httpMethod ?? "GET").uppercased()
        switch kind {
        case "radarr", "sonarr", "lidarr", "whisparr":
            if method == "GET" { return (Data("[]".utf8), "application/json") }
            return (Data(#"{"id":999999999}"#.utf8), "application/json")
        case "qbittorrent":
            return (Data("Ok.".utf8), "text/plain")
        case "sabnzbd":
            return (Data(#"{"status":true}"#.utf8), "application/json")
        case "transmission":
            return (Data(#"{"result":"success","arguments":{"torrents":[],"version":"0"}}"#.utf8), "application/json")
        case "deluge":
            return (Data(#"{"id":1,"result":true,"error":null}"#.utf8), "application/json")
        case "nzbget":
            return (Data(#"{"version":"1.1","result":true}"#.utf8), "application/json")
        case "rtorrent":
            return (Data(#"<?xml version="1.0"?><methodResponse><params><param><value><array><data/></array></value></param></params></methodResponse>"#.utf8),
                    "text/xml")
        case "plex":
            return (Data(#"{"MediaContainer":{"size":0}}"#.utf8), "application/json")
        default:
            return (Data("{}".utf8), "application/json")
        }
    }

    /// Hosts we deliberately point at `.invalid` so their writes are captured
    /// without a server: the family is encoded in the hostname.
    private static func kindGuess(host: String, url: URL?) -> String {
        for kind in ["transmission", "deluge", "rtorrent", "nzbget", "qbittorrent", "sabnzbd"]
        where host.contains(kind) { return kind }
        return "unknown"
    }

    // MARK: Loading

    override func startLoading() {
        let body = Self.bodyData(from: request)
        let ctx = Recorder.shared.context
        let url = request.url ?? URL(string: "about:blank")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let reason = Self.refusalReason(request, body: body)

        Recorder.shared.log(GoldenEntry(
            client: ctx.client,
            operation: ctx.operation,
            method: (request.httpMethod ?? "GET").uppercased(),
            path: Self.normalizePath(url.path),
            query_keys: (components?.queryItems ?? []).map(\.name).sorted(),
            header_names: (request.allHTTPHeaderFields ?? [:]).keys.sorted(),
            body: Self.scrubbedBody(body, contentType: request.value(forHTTPHeaderField: "Content-Type")),
            allowed: reason == nil,
            intercept_reason: reason,
            count: 1
        ))

        guard reason == nil else {
            let (data, contentType) = Self.synthetic(for: request)
            // Sonarr's V5 season endpoint is optimistic — the client falls back
            // to the V3 two-PUT dance on 404/405. A synthetic 200 would hide
            // that whole branch from the corpus, so answer it the way a Sonarr
            // without V5 does.
            let status = url.path.contains("/api/v5/") ? 404 : 200
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        var forward = URLRequest(url: url)
        forward.httpMethod = request.httpMethod
        forward.allHTTPHeaderFields = request.allHTTPHeaderFields
        forward.httpBody = body
        forward.timeoutInterval = 30
        forward.cachePolicy = .reloadIgnoringLocalCacheData

        let path = url.path
        let clientName = ctx.client
        let operation = ctx.operation

        Self.forwardSession.dataTask(with: forward) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let payload = data ?? Data()
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                guard let name = k as? String, let value = v as? String else { continue }
                // Cookies carry the session id.
                if name.lowercased().hasPrefix("set-cookie") { headers[name] = "<redacted>"; continue }
                headers[name] = value
            }
            Recorder.shared.store(RecordedResponse(
                client: clientName, operation: operation, path: path,
                status: http.statusCode, headers: headers, data: payload
            ))
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: payload)
            self.client?.urlProtocolDidFinishLoading(self)
        }.resume()
    }

    override func stopLoading() {}

    /// `/movie/1234` and `/movie/5678` are one request shape, not two.
    static func normalizePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, segment -> String in
                let s = String(segment)
                if s.isEmpty { return s }
                // TMDB's API version IS the first segment ("/3/movie/550") —
                // collapsing it to {id} would make every TMDB row unreadable.
                if index == 1 { return s }
                if Int(s) != nil { return "{id}" }
                if s.count >= 24, s.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return "{hash}" }
                return s
            }
            .joined(separator: "/")
    }

    static func scrubbedBody(_ data: Data?, contentType: String?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            let scrubbed = Scrub.json(obj, client: Recorder.shared.context.client)
            if let out = try? JSONSerialization.data(withJSONObject: scrubbed,
                                                     options: [.sortedKeys, .fragmentsAllowed]) {
                return String(data: out, encoding: .utf8)
            }
        }
        guard var text = String(data: data, encoding: .utf8) else {
            return "<binary \(data.count) bytes>"
        }
        if (contentType ?? "").contains("x-www-form-urlencoded") {
            text = text.split(separator: "&").map { pair -> String in
                let parts = pair.split(separator: "=", maxSplits: 1)
                let name = String(parts.first ?? "")
                if Scrub.matches(Scrub.secretKey, name) { return "\(name)=<redacted>" }
                return String(pair)
            }.joined(separator: "&")
        }
        if (contentType ?? "").contains("multipart/form-data") {
            // Boundary + file bytes are noise; keep the field names only.
            let names = text.components(separatedBy: "name=\"").dropFirst()
                .compactMap { $0.split(separator: "\"").first.map(String.init) }
            return "<multipart fields: \(names.joined(separator: ", "))>"
        }
        return Scrub.text(String(text.prefix(4000)))
    }
}

// MARK: - The driver

@Suite("Phase 0 recording", .serialized)
struct Phase0RecordingTests {

    private var recording: Bool { ProcessInfo.processInfo.environment["ARRBARR_RECORD"] == "1" }

    @Test("Record golden requests and live fixtures")
    func record() async throws {
        guard recording else { return }
        #expect(DemoMode.isActive == false, "recording must run against the real profile")

        let stored = StoredConfig()
        URLProtocol.registerClass(RecordingProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingProtocol.self) }

        // ---- wire up the live-host table -------------------------------
        var liveHosts: [String: String] = [:]
        var aliases: [String: String] = [:]
        var arrBase: [String: String] = [:]

        let radarrCfg = stored.service(.radarr)
        let sonarrCfg = stored.service(.sonarr)
        let lidarrCfg = stored.service(.lidarr)
        let whisparrCfg = stored.service(.whisparr)
        let qbitCfg = stored.service(.qbittorrent)
        let sabCfg = stored.service(.sabnzbd)
        let mediaCfg = stored.mediaServer

        func register(_ cfg: ServiceConfig, _ key: String, base: String? = nil) {
            guard cfg.isConfigured, let host = URL(string: cfg.baseURL)?.host else { return }
            liveHosts[host] = key
            aliases[host] = "\(key).local"
            if let base { arrBase[key] = base }
        }
        register(radarrCfg, "radarr", base: "/api/v3")
        register(sonarrCfg, "sonarr", base: "/api/v3")
        register(lidarrCfg, "lidarr", base: "/api/v1")
        register(whisparrCfg, "whisparr", base: "/api/v3")
        register(qbitCfg, "qbittorrent")
        register(sabCfg, "sabnzbd")
        if mediaCfg.isConfigured, let host = URL(string: mediaCfg.baseURL)?.host {
            let key = mediaCfg.kind == .plex ? "plex" : "jellyfin"
            liveHosts[host] = key
            aliases[host] = "\(key).local"
        }
        if !stored.tmdbKey.isEmpty { liveHosts["api.themoviedb.org"] = "tmdb" }

        Recorder.shared.configure(liveHosts: liveHosts, arrBase: arrBase,
                                  hostAliases: aliases, secrets: stored.knownSecrets)

        // ---- arrs ------------------------------------------------------
        if radarrCfg.isConfigured { await driveRadarr(radarrCfg) }
        if sonarrCfg.isConfigured { await driveSonarr(sonarrCfg) }
        if lidarrCfg.isConfigured { await driveLidarr(lidarrCfg) }
        if whisparrCfg.isConfigured {
            await driveWhisparr(whisparrCfg)
        } else {
            Recorder.shared.note("whisparr: not configured on this machine — skipped")
        }

        // ---- search / add ----------------------------------------------
        if radarrCfg.isConfigured { await driveSearch(radarrCfg, source: .radarr) }
        if sonarrCfg.isConfigured { await driveSearch(sonarrCfg, source: .sonarr) }
        if lidarrCfg.isConfigured { await driveSearch(lidarrCfg, source: .lidarr) }

        // ---- realtime negotiate ----------------------------------------
        if sonarrCfg.isConfigured { await driveNegotiate(sonarrCfg) }

        // ---- download clients ------------------------------------------
        await driveQbittorrent(qbitCfg)
        await driveSabnzbd(sabCfg)
        await driveTransmission(stored.service(.transmission))
        await driveOfflineClients()

        // ---- media server ----------------------------------------------
        if mediaCfg.isConfigured { await driveMediaServer(mediaCfg) }

        // ---- TMDB -------------------------------------------------------
        if !stored.tmdbKey.isEmpty { await driveTMDB(stored.tmdbKey) }

        try writeOutputs()
    }

    // MARK: step helper

    private func step(_ client: String, _ op: String, _ work: () async throws -> Void) async {
        Recorder.shared.begin(client, op)
        do { try await work() } catch {
            Recorder.shared.note("\(client).\(op): \(Scrub.text(error.userFacingMessage))")
        }
    }

    // MARK: Radarr

    private func driveRadarr(_ cfg: ServiceConfig) async {
        let c = RadarrClient(config: cfg)
        var movieId = 999_999_999

        await step("radarr", "testConnection") { _ = try await c.testConnection() }
        await step("radarr", "fetchHealth") { _ = try await c.fetchHealth() }
        await step("radarr", "fetchDiskSpace") { _ = try await c.fetchDiskSpace() }
        await step("radarr", "fetchAllMovies") {
            let movies = try await c.fetchAllMovies()
            if let id = movies.first?.id { movieId = id }
            Recorder.shared.note("radarr: library holds \(movies.count) movies")
            _ = await c.alternateTitleMap(for: Array(movies.prefix(3)))
        }
        await step("radarr", "alternateTitleMap") {
            _ = await c.alternateTitleMap(for: [])
        }
        await step("radarr", "fetchQueue") { _ = try await c.fetchQueue() }
        await step("radarr", "fetchCalendar") { _ = try await c.fetchCalendar() }
        await step("radarr", "fetchHistory") { _ = try await c.fetchHistory(page: 1, pageSize: 20) }
        await step("radarr", "fetchHistoryForMovie") {
            _ = try await c.fetchHistory(page: 1, pageSize: 20, entityId: movieId)
        }
        await step("radarr", "fetchMovieDetails") { _ = try await c.fetchMovieDetails(id: movieId) }
        await step("radarr", "fetchMovieFile") { _ = try await c.fetchMovieFile(movieId: movieId) }
        await step("radarr", "fetchCredits") { _ = try await c.fetchCredits(movieId: movieId) }
        await step("radarr", "fetchQualityProfiles") { _ = try await c.fetchQualityProfiles() }
        await step("radarr", "fetchCustomFormats") { _ = try await c.fetchCustomFormats() }
        await step("radarr", "fetchDownloadClients") { _ = try await c.fetchDownloadClients() }
        await step("radarr", "isSearchRunning") { _ = await c.isSearchRunning(entityId: movieId) }

        // Writes — intercepted, never sent.
        await step("radarr", "searchMovie") { try await c.searchMovie(movieId: movieId) }
        await step("radarr", "postCommand") {
            try await c.postCommand(["name": "RefreshMovie", "movieId": movieId])
        }
        await step("radarr", "setMovieMonitored") {
            try await c.setMovieMonitored(movieId: movieId, monitored: true)
        }
        await step("radarr", "updateLibraryRecord") {
            try await c.updateLibraryRecord(path: "/movie/\(movieId)",
                                            fields: ["qualityProfileId": 1, "monitored": true])
        }
        await step("radarr", "deleteLibraryRecord") {
            try await c.deleteLibraryRecord(path: "/movie/999999999", deleteFiles: false,
                                            addImportExclusion: false)
        }
        await step("radarr", "deleteQueueItem") {
            try await c.deleteQueueItem(id: 999_999_999, removeFromClient: true, blocklist: false)
        }
        await step("radarr", "grabQueueItem") { try await c.grabQueueItem(id: 999_999_999) }
        await step("radarr", "fetchReleases") {
            _ = try await c.fetchReleases(query: [URLQueryItem(name: "movieId", value: "999999999")])
        }
        await step("radarr", "grabRelease") {
            try await c.grabRelease(guid: "recording-placeholder", indexerId: 999_999_999)
        }
    }

    // MARK: Sonarr

    private func driveSonarr(_ cfg: ServiceConfig) async {
        let c = SonarrClient(config: cfg)
        var seriesId = 999_999_999
        var episodeIds: [Int] = [999_999_999]

        await step("sonarr", "testConnection") { _ = try await c.testConnection() }
        await step("sonarr", "fetchHealth") { _ = try await c.fetchHealth() }
        await step("sonarr", "fetchDiskSpace") { _ = try await c.fetchDiskSpace() }
        await step("sonarr", "fetchAllSeries") {
            let all = try await c.fetchAllSeries()
            if let id = all.first?.id { seriesId = id }
            Recorder.shared.note("sonarr: library holds \(all.count) series")
        }
        await step("sonarr", "fetchQueue") { _ = try await c.fetchQueue() }
        await step("sonarr", "fetchCalendar") { _ = try await c.fetchCalendar() }
        await step("sonarr", "fetchHistory") { _ = try await c.fetchHistory(page: 1, pageSize: 20) }
        await step("sonarr", "fetchHistoryForSeries") {
            _ = try await c.fetchHistory(page: 1, pageSize: 20, entityId: seriesId)
        }
        await step("sonarr", "fetchSeriesDetails") { _ = try await c.fetchSeriesDetails(id: seriesId) }
        await step("sonarr", "fetchEpisodes") {
            let episodes = try await c.fetchEpisodes(seriesId: seriesId)
            if let id = episodes.first?.id { episodeIds = [id] }
        }
        await step("sonarr", "fetchEpisodeFileMap") { _ = try await c.fetchEpisodeFileMap(seriesId: seriesId) }
        await step("sonarr", "fetchQualityProfiles") { _ = try await c.fetchQualityProfiles() }
        await step("sonarr", "fetchCustomFormats") { _ = try await c.fetchCustomFormats() }
        await step("sonarr", "fetchDownloadClients") { _ = try await c.fetchDownloadClients() }
        await step("sonarr", "isSearchRunning") { _ = await c.isSearchRunning(entityId: seriesId) }

        await step("sonarr", "searchSeries") { try await c.searchSeries(seriesId: seriesId) }
        await step("sonarr", "searchSeason") { try await c.searchSeason(seriesId: seriesId, seasonNumber: 1) }
        await step("sonarr", "searchEpisodes") { try await c.searchEpisodes(episodeIds: episodeIds) }
        await step("sonarr", "setSeriesMonitored") {
            try await c.setSeriesMonitored(seriesId: seriesId, monitored: true)
        }
        await step("sonarr", "setSeasonMonitored") {
            try await c.setSeasonMonitored(seriesId: seriesId, seasonNumber: 1, monitored: true)
        }
        await step("sonarr", "setEpisodesMonitored") {
            try await c.setEpisodesMonitored(episodeIds: episodeIds, monitored: true)
        }
        await step("sonarr", "updateLibraryRecord") {
            try await c.updateLibraryRecord(path: "/series/\(seriesId)", fields: ["monitored": true])
        }
        await step("sonarr", "deleteLibraryRecord") {
            try await c.deleteLibraryRecord(path: "/series/999999999", deleteFiles: false,
                                            addImportExclusion: false)
        }
        await step("sonarr", "deleteQueueItem") { try await c.deleteQueueItem(id: 999_999_999) }
        await step("sonarr", "grabQueueItem") { try await c.grabQueueItem(id: 999_999_999) }
        await step("sonarr", "fetchReleases") {
            _ = try await c.fetchReleases(query: [URLQueryItem(name: "episodeId", value: "999999999")])
        }
        await step("sonarr", "grabRelease") {
            try await c.grabRelease(guid: "recording-placeholder", indexerId: 999_999_999)
        }
    }

    // MARK: Lidarr

    private func driveLidarr(_ cfg: ServiceConfig) async {
        let c = LidarrClient(config: cfg)
        var artistId = 999_999_999
        var albumId = 999_999_999

        await step("lidarr", "testConnection") { _ = try await c.testConnection() }
        await step("lidarr", "fetchHealth") { _ = try await c.fetchHealth() }
        await step("lidarr", "fetchDiskSpace") { _ = try await c.fetchDiskSpace() }
        await step("lidarr", "fetchAllArtists") {
            let artists = try await c.fetchAllArtists()
            if let id = artists.first?.id { artistId = id }
            Recorder.shared.note("lidarr: library holds \(artists.count) artists")
        }
        await step("lidarr", "fetchArtistAlbums") {
            let albums = try await c.fetchArtistAlbums(artistId: artistId)
            if let id = albums.first?.id { albumId = id }
        }
        await step("lidarr", "fetchQueue") { _ = try await c.fetchQueue() }
        await step("lidarr", "fetchCalendar") { _ = try await c.fetchCalendar() }
        await step("lidarr", "fetchHistory") { _ = try await c.fetchHistory(page: 1, pageSize: 20) }
        await step("lidarr", "fetchHistoryForAlbum") {
            _ = try await c.fetchHistory(page: 1, pageSize: 20, entityId: albumId)
        }
        await step("lidarr", "fetchArtistDetails") { _ = try await c.fetchArtistDetails(id: artistId) }
        await step("lidarr", "fetchAlbumDetails") { _ = try await c.fetchAlbumDetails(id: albumId) }
        await step("lidarr", "fetchTracks") { _ = try await c.fetchTracks(albumId: albumId) }
        await step("lidarr", "fetchTrackFiles") { _ = try await c.fetchTrackFiles(albumId: albumId) }
        await step("lidarr", "fetchQualityProfiles") { _ = try await c.fetchQualityProfiles() }
        await step("lidarr", "fetchCustomFormats") { _ = try await c.fetchCustomFormats() }
        await step("lidarr", "fetchDownloadClients") { _ = try await c.fetchDownloadClients() }
        await step("lidarr", "isSearchRunning") { _ = await c.isSearchRunning(entityId: albumId) }

        await step("lidarr", "searchAlbum") { try await c.searchAlbum(albumId: albumId) }
        await step("lidarr", "setAlbumMonitored") {
            try await c.setAlbumMonitored(albumId: albumId, monitored: true)
        }
        await step("lidarr", "setArtistMonitored") {
            try await c.setArtistMonitored(artistId: artistId, monitored: true)
        }
        await step("lidarr", "updateLibraryRecord") {
            try await c.updateLibraryRecord(path: "/artist/\(artistId)", fields: ["monitored": true])
        }
        await step("lidarr", "deleteLibraryRecord") {
            try await c.deleteLibraryRecord(path: "/artist/999999999", deleteFiles: false,
                                            addImportExclusion: false)
        }
        await step("lidarr", "deleteQueueItem") { try await c.deleteQueueItem(id: 999_999_999) }
        await step("lidarr", "fetchReleases") {
            _ = try await c.fetchReleases(query: [URLQueryItem(name: "albumId", value: "999999999")])
        }
    }

    // MARK: Whisparr

    private func driveWhisparr(_ cfg: ServiceConfig) async {
        let c = WhisparrClient(config: cfg)
        var movieId = 999_999_999
        await step("whisparr", "testConnection") { _ = try await c.testConnection() }
        await step("whisparr", "fetchAllMovies") {
            let all = try await c.fetchAllMovies()
            if let id = all.first?.id { movieId = id }
        }
        await step("whisparr", "fetchQueue") { _ = try await c.fetchQueue() }
        await step("whisparr", "fetchCalendar") { _ = try await c.fetchCalendar() }
        await step("whisparr", "fetchHistory") { _ = try await c.fetchHistory(page: 1, pageSize: 20) }
        await step("whisparr", "fetchMovieDetails") { _ = try await c.fetchMovieDetails(id: movieId) }
        await step("whisparr", "fetchMovieFile") { _ = try await c.fetchMovieFile(movieId: movieId) }
        await step("whisparr", "setMovieMonitored") {
            try await c.setMovieMonitored(movieId: movieId, monitored: true)
        }
    }

    // MARK: Search / add

    private func driveSearch(_ cfg: ServiceConfig, source: QueueItem.Source) async {
        let name = source.rawValue
        let c = SearchClient(config: cfg, source: source)
        var results: [SearchResult] = []
        let term = source == .lidarr ? "radiohead" : "matrix"

        await step(name, "search.lookup") {
            results = try await c.lookup(query: term)
            Recorder.shared.note("\(name): lookup(\(term)) returned \(results.count) rows")
        }
        await step(name, "search.fetchQualityProfiles") { _ = try await c.fetchQualityProfiles() }
        await step(name, "search.fetchMetadataProfiles") { _ = try await c.fetchMetadataProfiles() }
        await step(name, "search.fetchRootFolders") {
            let folders = try await c.fetchRootFolders()
            for folder in folders { Recorder.shared.addRootPath(folder.path, kind: name) }
        }
        await step(name, "search.fetchLibraryOwnership") { _ = try await c.fetchLibraryOwnership() }

        guard let first = results.first else {
            Recorder.shared.note("\(name): no lookup result — add-path bodies not recorded")
            return
        }
        switch source {
        case .radarr:
            await step(name, "search.addMovie") {
                _ = try await c.addMovie(first, qualityProfileId: 1, rootFolderPath: "/data/\(name)",
                                         monitor: .movieOnly, searchOnAdd: false)
            }
        case .sonarr:
            await step(name, "search.addSeries") {
                _ = try await c.addSeries(first, qualityProfileId: 1, rootFolderPath: "/data/\(name)",
                                          monitor: .all, seriesType: .standard,
                                          seasonFolder: true, searchOnAdd: false)
            }
        case .lidarr:
            await step(name, "search.addArtist") {
                _ = try await c.addArtist(first, qualityProfileId: 1, metadataProfileId: 1,
                                          rootFolderPath: "/data/\(name)", searchOnAdd: false)
            }
            await step(name, "search.addAlbum") {
                _ = try await c.addAlbum(first, qualityProfileId: 1, metadataProfileId: 1,
                                         rootFolderPath: "/data/\(name)", searchOnAdd: false)
            }
        case .whisparr:
            await step(name, "search.addScene") {
                _ = try await c.addScene(first, qualityProfileId: 1, rootFolderPath: "/data/\(name)",
                                         searchOnAdd: false)
            }
        }
    }

    // MARK: Realtime negotiate

    private func driveNegotiate(_ cfg: ServiceConfig) async {
        await step("sonarr", "realtime.negotiate") {
            let http = HTTPClient()
            var base = cfg.baseURL
            while base.hasSuffix("/") { base.removeLast() }
            let url = try http.url(base: base, path: "/signalr/messages/negotiate",
                                   query: [URLQueryItem(name: "negotiateVersion", value: "1")])
            _ = try await http.post(url, headers: ["X-Api-Key": cfg.apiKey], body: Data())
        }
    }

    // MARK: Download clients

    private func driveQbittorrent(_ cfg: ServiceConfig) async {
        guard cfg.isConfigured else {
            Recorder.shared.note("qbittorrent: not configured — skipped")
            return
        }
        let c = QbittorrentClient(config: cfg, session: Self.recordingSession())
        let hash = "0000000000000000000000000000000000000000"
        await step("qbittorrent", "testConnection") { _ = try await c.testConnection() }
        await step("qbittorrent", "fetchProgress") { _ = try await c.fetchProgress(ids: []) }
        await step("qbittorrent", "contains") { _ = try await c.contains(hash: hash) }
        await step("qbittorrent", "defaultAddPaused") { _ = await c.defaultAddPaused() }
        await step("qbittorrent", "pause") { try await c.perform(.pause, hash: hash) }
        await step("qbittorrent", "resume") { try await c.perform(.resume, hash: hash) }
        await step("qbittorrent", "forceStart") { try await c.perform(.forceStart, hash: hash) }
        await step("qbittorrent", "delete") { try await c.perform(.delete, hash: hash) }
        await step("qbittorrent", "addMagnet") {
            try await c.add(Self.magnetDrop(), category: "radarr", paused: false)
        }
        await step("qbittorrent", "addFile") {
            try await c.add(Self.torrentDrop(), category: "radarr", paused: true)
        }
    }

    private func driveSabnzbd(_ cfg: ServiceConfig) async {
        guard cfg.isConfigured else {
            Recorder.shared.note("sabnzbd: not configured — skipped")
            return
        }
        let c = SabnzbdClient(config: cfg, session: Self.recordingSession())
        await step("sabnzbd", "testConnection") { _ = try await c.testConnection() }
        await step("sabnzbd", "fetchProgress") { _ = try await c.fetchProgress(ids: []) }
        await step("sabnzbd", "contains") { _ = try await c.contains(nzoId: "SABnzbd_nzo_000000") }
        await step("sabnzbd", "pause") { try await c.perform(.pause, nzoId: "SABnzbd_nzo_000000") }
        await step("sabnzbd", "resume") { try await c.perform(.resume, nzoId: "SABnzbd_nzo_000000") }
        await step("sabnzbd", "delete") { try await c.perform(.delete, nzoId: "SABnzbd_nzo_000000") }
        await step("sabnzbd", "addFile") {
            try await c.add(Self.nzbDrop(), category: "sonarr", paused: false)
        }
        // `mode=history` is on the allow-list but has no client method today —
        // record it so the rewrite's history-backed UI has a fixture.
        await step("sabnzbd", "history") {
            let http = HTTPClient()
            let url = try http.url(base: cfg.baseURL, path: "/api", query: [
                URLQueryItem(name: "mode", value: "history"),
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "output", value: "json"),
                URLQueryItem(name: "apikey", value: cfg.apiKey),
            ])
            _ = try await http.get(url)
        }
    }

    private func driveTransmission(_ cfg: ServiceConfig) async {
        // Transmission is not reachable on this machine. Point it at an
        // `.invalid` host so every RPC is intercepted and the request shapes
        // still reach the corpus.
        var probe = cfg
        probe.enabled = true
        probe.baseURL = "http://transmission.invalid:9091"
        let c = TransmissionClient(config: probe, session: Self.recordingSession())
        let hash = "0000000000000000000000000000000000000000"
        await step("transmission", "testConnection") { _ = try await c.testConnection() }
        await step("transmission", "fetchProgress") { _ = try await c.fetchProgress(ids: [hash]) }
        await step("transmission", "pause") { try await c.perform(.pause, hash: hash) }
        await step("transmission", "resume") { try await c.perform(.resume, hash: hash) }
        await step("transmission", "delete") { try await c.perform(.delete, hash: hash) }
        await step("transmission", "addMagnet") {
            try await c.add(Self.magnetDrop(), category: nil, paused: false)
        }
        Recorder.shared.note("transmission: intercepted only (disabled in config, host unreachable)")
    }

    private func driveOfflineClients() async {
        let hash = "0000000000000000000000000000000000000000"

        var deluge = ServiceConfig.empty
        deluge.enabled = true
        deluge.baseURL = "http://deluge.invalid:8112"
        deluge.password = "recording-placeholder"
        let d = DelugeClient(config: deluge, session: Self.recordingSession())
        await step("deluge", "testConnection") { _ = try await d.testConnection() }
        await step("deluge", "fetchProgress") { _ = try await d.fetchProgress(ids: [hash]) }
        await step("deluge", "pause") { try await d.perform(.pause, hash: hash) }
        await step("deluge", "resume") { try await d.perform(.resume, hash: hash) }
        await step("deluge", "delete") { try await d.perform(.delete, hash: hash) }
        await step("deluge", "addMagnet") { try await d.add(Self.magnetDrop(), category: nil, paused: false) }

        var nzbget = ServiceConfig.empty
        nzbget.enabled = true
        nzbget.baseURL = "http://nzbget.invalid:6789"
        nzbget.username = "recording"
        nzbget.password = "recording-placeholder"
        let n = NzbgetClient(config: nzbget, session: Self.recordingSession())
        await step("nzbget", "testConnection") { _ = try await n.testConnection() }
        await step("nzbget", "fetchProgress") { _ = try await n.fetchProgress(ids: []) }
        await step("nzbget", "pause") { try await n.perform(.pause, nzbId: "1") }
        await step("nzbget", "resume") { try await n.perform(.resume, nzbId: "1") }
        await step("nzbget", "delete") { try await n.perform(.delete, nzbId: "1") }
        await step("nzbget", "addFile") { try await n.add(Self.nzbDrop(), category: "sonarr", paused: false) }

        var rtorrent = ServiceConfig.empty
        rtorrent.enabled = true
        rtorrent.baseURL = "http://rtorrent.invalid/RPC2"
        let r = RtorrentClient(config: rtorrent, session: Self.recordingSession())
        await step("rtorrent", "testConnection") { _ = try await r.testConnection() }
        await step("rtorrent", "fetchProgress") { _ = try await r.fetchProgress(ids: [hash]) }
        await step("rtorrent", "pause") { try await r.perform(.pause, hash: hash) }
        await step("rtorrent", "resume") { try await r.perform(.resume, hash: hash) }
        await step("rtorrent", "delete") { try await r.perform(.delete, hash: hash) }
        await step("rtorrent", "addMagnet") { try await r.add(Self.magnetDrop(), category: nil, paused: false) }
    }

    // MARK: Media server

    private func driveMediaServer(_ cfg: MediaServerConfig) async {
        guard let c = MediaServerClientFactory.make(config: cfg) else { return }
        let name = cfg.kind == .plex ? "plex" : "jellyfin"
        var seriesItemId = ""
        var seriesCandidates: [String] = []

        await step(name, "testConnection") { _ = try await c.testConnection() }
        await step(name, "libraries") { _ = try await c.libraries() }
        await step(name, "libraryIndex") {
            let entries = try await c.libraryIndex()
            Recorder.shared.note("\(name): index holds \(entries.count) entries")
            // A series is the one that carries a TVDB key.
            seriesCandidates = entries.filter { entry in
                entry.externalKeys.contains { if case .tvdb = $0 { return true } else { return false } }
            }.map(\.itemId)
            seriesItemId = seriesCandidates.first ?? ""
        }
        await step(name, "nowPlaying") { _ = try await c.nowPlaying() }
        await step(name, "recentlyWatched") { _ = try await c.recentlyWatched(limit: 20) }
        await step(name, "seasonPosters") {
            // Plex answers 400 for a ratingKey that has no children, and which
            // index entries are series is only knowable by asking — try a few.
            for candidate in seriesCandidates.prefix(5) {
                if let posters = try? await c.seasonPosters(seriesItemId: candidate), !posters.isEmpty {
                    return
                }
            }
            if !seriesItemId.isEmpty { _ = try await c.seasonPosters(seriesItemId: seriesItemId) }
        }
        // Maintenance writes — intercepted, never sent.
        await step(name, "scanLibrary") { try await c.scanLibrary(id: "1") }
        await step(name, "emptyTrash") { try await c.emptyTrash(libraryId: "1") }
    }

    // MARK: TMDB

    private func driveTMDB(_ key: String) async {
        let c = TMDBClient(apiKey: key)
        let movieId = 550          // a stable public TMDB movie id
        let tvId = 1399            // a stable public TMDB series id
        let personId = 287         // a stable public TMDB person id
        let tvdbId = 121361

        await step("tmdb", "testConnection") { try await c.testConnection() }
        await step("tmdb", "searchPerson") { _ = try await c.searchPerson(query: "nolan") }
        await step("tmdb", "movieCredits") { _ = try await c.movieCredits(movieId: movieId) }
        await step("tmdb", "tvCredits") { _ = try await c.tvCredits(tvId: tvId) }
        await step("tmdb", "tvCreators") { _ = try await c.tvCreators(tvId: tvId) }
        await step("tmdb", "tvIdFromTVDB") { _ = try await c.tvIdFromTVDB(tvdbId) }
        await step("tmdb", "tvdbIdFromTVId") { _ = try await c.tvdbIdFromTVId(tvId) }
        await step("tmdb", "personDetails") { _ = try await c.personDetails(personId: personId) }
        await step("tmdb", "personMovieCredits") { _ = try await c.personMovieCredits(personId: personId) }
        await step("tmdb", "personTVCredits") { _ = try await c.personTVCredits(personId: personId) }
        await step("tmdb", "discoverMovies") { _ = try await c.discoverMovies() }
        await step("tmdb", "discoverTV") { _ = try await c.discoverTV() }
        await step("tmdb", "similarMovies") { _ = try await c.similarMovies(movieId: movieId) }
        await step("tmdb", "similarTV") { _ = try await c.similarTV(seriesId: tvId) }
        await step("tmdb", "recommendedMovies") { _ = try await c.recommendedMovies(movieId: movieId) }
        await step("tmdb", "recommendedTV") { _ = try await c.recommendedTV(seriesId: tvId) }
        await step("tmdb", "movieVideos") { _ = try await c.movieVideos(movieId: movieId) }
        await step("tmdb", "tvVideos") { _ = try await c.tvVideos(tvId: tvId) }
        await step("tmdb", "movieCountries") { _ = try await c.movieCountries(movieId: movieId) }
        await step("tmdb", "tvCountries") { _ = try await c.tvCountries(tvId: tvId) }
    }

    // MARK: fixtures / helpers

    private static func recordingSession() -> URLSession {
        let cfg = HTTPClient.uncachedConfiguration()
        cfg.protocolClasses = [RecordingProtocol.self]
        cfg.httpCookieStorage = HTTPCookieStorage()
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        return URLSession(configuration: cfg)
    }

    private static func magnetDrop() -> DownloadDrop {
        DownloadDrop(
            content: .magnet("magnet:?xt=urn:btih:0000000000000000000000000000000000000000&dn=Recording+Placeholder"),
            kind: .torrent,
            displayName: "Recording Placeholder"
        )
    }

    private static func torrentDrop() -> DownloadDrop {
        DownloadDrop(content: .file(Data("d8:announce0:e".utf8), filename: "placeholder.torrent"),
                     kind: .torrent, displayName: "placeholder.torrent")
    }

    private static func nzbDrop() -> DownloadDrop {
        DownloadDrop(content: .file(Data("<nzb/>".utf8), filename: "placeholder.nzb"),
                     kind: .usenet, displayName: "placeholder.nzb")
    }

    // MARK: Output

    private func writeOutputs() throws {
        let fm = FileManager.default

        // --- golden corpus ----------------------------------------------
        let entries = Recorder.shared.entries.values.sorted {
            ($0.client, $0.operation, $0.method, $0.path) < ($1.client, $1.operation, $1.method, $1.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let corpus = try encoder.encode(entries)
        try fm.createDirectory(atPath: (RecPaths.baselineFile as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try corpus.write(to: URL(fileURLWithPath: RecPaths.baselineFile))

        // --- fixtures ----------------------------------------------------
        var used: Set<String> = []
        var seenPaths: Set<String> = []
        var written: [[String: Any]] = []

        for response in Recorder.shared.responses {
            let normalized = RecordingProtocol.normalizePath(response.path)
            let identity = "\(response.client)|\(response.operation)|\(normalized)"
            guard !seenPaths.contains(identity) else { continue }   // side-loads repeat
            seenPaths.insert(identity)
            // A fixture is a shape the rewrite must decode; an error page is
            // not one. The raw recording keeps the failure either way.
            guard (200..<400).contains(response.status) else {
                Recorder.shared.note(
                    "\(response.client).\(response.operation): HTTP \(response.status) — no fixture written")
                continue
            }

            var name = Scrub.slug(response.operation)
            if used.contains("\(response.client)/\(name)") {
                name = Scrub.slug("\(response.operation)-\(normalized)")
            }
            var unique = name
            var n = 2
            while used.contains("\(response.client)/\(unique)") {
                unique = "\(name)-\(n)"; n += 1
            }
            used.insert("\(response.client)/\(unique)")

            guard let decoded = try? JSONSerialization.jsonObject(with: response.data,
                                                                  options: [.fragmentsAllowed]) else {
                // Non-JSON payloads (qBittorrent's plain-text version) are kept
                // as a quoted string so the fixture is still valid JSON.
                let text = Scrub.text(String(data: response.data, encoding: .utf8) ?? "")
                try writeFixture(client: response.client, name: unique, value: text,
                                 counts: [:], truncated: false, response: response)
                written.append(["client": response.client, "operation": response.operation,
                                "fixture": "\(response.client)/\(unique).json", "path": normalized])
                continue
            }

            var scrubbed = Scrub.json(decoded, client: response.client)
            if response.client == "whisparr" {
                var counter = 0
                scrubbed = Scrub.titlesOnly(scrubbed, counter: &counter)
            }
            let (truncatedValue, counts, didTruncate) = Truncate.apply(scrubbed)
            try writeFixture(client: response.client, name: unique, value: truncatedValue,
                             counts: counts, truncated: didTruncate, response: response)
            written.append(["client": response.client, "operation": response.operation,
                            "fixture": "\(response.client)/\(unique).json", "path": normalized])
        }

        // --- run report (scratchpad only) --------------------------------
        let report: [String: Any] = [
            "entries": entries.count,
            "fixtures": written,
            "notes": Recorder.shared.notes,
        ]
        try fm.createDirectory(atPath: RecPaths.rawRoot, withIntermediateDirectories: true)
        let reportData = try JSONSerialization.data(withJSONObject: report,
                                                    options: [.prettyPrinted, .sortedKeys])
        try reportData.write(to: URL(fileURLWithPath: RecPaths.reportFile))
    }

    private func writeFixture(client: String, name: String, value: Any,
                              counts: [String: Int], truncated: Bool,
                              response: RecordedResponse) throws {
        let fm = FileManager.default
        let dir = "\(RecPaths.fixturesRoot)/\(client)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let body = try JSONSerialization.data(withJSONObject: value,
                                              options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        try body.write(to: URL(fileURLWithPath: "\(dir)/\(name).json"))

        var headers: [String: String] = [:]
        for (k, v) in response.headers {
            if Scrub.matches(Scrub.secretKey, k) || k.lowercased().hasPrefix("set-cookie") {
                headers[k] = "<redacted>"
            } else {
                headers[k] = Scrub.text(v)
            }
        }
        let meta: [String: Any] = [
            "status": response.status,
            "headers": headers,
            "recorded_at": RecPaths.recordedAt,
            "operation": response.operation,
            "request_path": Scrub.text(RecordingProtocol.normalizePath(response.path)),
            "original_array_count": counts,
            "truncated": truncated,
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta,
                                                  options: [.prettyPrinted, .sortedKeys])
        try metaData.write(to: URL(fileURLWithPath: "\(dir)/\(name).meta.json"))
    }
}
