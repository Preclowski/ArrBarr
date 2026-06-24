import Foundation

public enum DelugeError: LocalizedError {
    case authFailed
    case actionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .authFailed: return "Deluge: authentication failed"
        case .actionFailed(let msg): return "Deluge: \(msg)"
        }
    }
}

public actor DelugeClient: DownloadProgressSource {
    enum Action { case pause, resume, delete }

    private let config: ServiceConfig
    private let session: URLSession
    private let http: HTTPClient
    private var loggedIn = false
    private var requestId = 0
    /// In-flight login, shared so concurrent actions await one `auth.login`.
    private var loginTask: Task<Void, Error>?

    init(config: ServiceConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
            self.http = HTTPClient(session: session)
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.httpCookieStorage = HTTPCookieStorage()
            cfg.httpCookieAcceptPolicy = .always
            cfg.httpShouldSetCookies = true
            let s = URLSession(configuration: cfg)
            self.session = s
            self.http = HTTPClient(session: s)
        }
    }

    func perform(_ action: Action, hash: String) async throws {
        try await ensureLoggedIn()

        let method: String
        let params: [Any]

        switch action {
        case .pause:
            method = "core.pause_torrent"
            params = [[hash]]
        case .resume:
            method = "core.resume_torrent"
            params = [[hash]]
        case .delete:
            method = "core.remove_torrent"
            params = [hash, false]
        }

        let resp = try await rpc(method: method, params: params)
        if let error = resp["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw DelugeError.actionFailed(message)
        }
    }

    func testConnection() async throws -> String {
        try await ensureLoggedIn()
        let resp = try await rpc(method: "daemon.info", params: [])
        if let version = resp["result"] as? String {
            return "Deluge \(version)"
        }
        return "OK"
    }

    /// Batch live progress via `core.get_torrents_status({}, [keys])`, which
    /// returns `{ infohash: { progress, download_payload_rate } }`. Deluge's
    /// `progress` is a 0…100 float, so it's scaled to 0…1. Keyed by lowercased
    /// hash to match the arr's download id.
    public func fetchProgress() async throws -> [String: DownloadProgress] {
        guard config.isConfigured else { return [:] }
        try await ensureLoggedIn()
        let resp = try await rpc(
            method: "core.get_torrents_status",
            params: [[String: Any](), ["progress", "download_payload_rate"]]
        )
        guard let result = resp["result"] as? [String: Any] else { return [:] }
        var map: [String: DownloadProgress] = [:]
        for (hash, value) in result {
            guard let status = value as? [String: Any] else { continue }
            let progress = ((status["progress"] as? Double) ?? 0) / 100
            let rate = (status["download_payload_rate"] as? Int).map(Int64.init)
            map[hash.lowercased()] = DownloadProgress(progress: progress, downloadSpeed: rate)
        }
        return map
    }

    private func ensureLoggedIn() async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        if loggedIn { return }
        if let task = loginTask { try await task.value; return }

        let task = Task { try await self.performLogin() }
        loginTask = task
        defer { loginTask = nil }
        try await task.value
    }

    private func performLogin() async throws {
        let resp = try await rpc(method: "auth.login", params: [config.password])
        guard resp["result"] as? Bool == true else {
            throw DelugeError.authFailed
        }
        loggedIn = true
    }

    private func rpc(method: String, params: [Any]) async throws -> [String: Any] {
        requestId += 1
        let body: [String: Any] = ["method": method, "params": params, "id": requestId]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let url = try http.url(base: config.baseURL, path: "/json")
        let data = try await http.post(
            url,
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: jsonData
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.decoding(
                NSError(domain: "Deluge", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
            )
        }
        return json
    }
}
