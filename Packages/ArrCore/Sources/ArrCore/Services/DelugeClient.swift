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
    /// Whether `auth.login` has established a live session cookie. Cleared
    /// again by `invalidateSession(generation:)` when Deluge rejects an RPC:
    /// the cookie expires (and every session dies with a daemon restart) while
    /// this actor stays cached for the app's lifetime.
    private var loggedIn = false
    /// Bumped by every successful login. An RPC captures the generation it was
    /// sent under, so a rejection can only invalidate *that* session — a burst
    /// of stale RPCs re-authenticates once instead of each tearing down the
    /// session the previous one just established.
    private var sessionGeneration = 0
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

        let resp = try await authenticated { try await rpc(method: method, params: params) }
        if let error = resp["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw DelugeError.actionFailed(message)
        }
    }

    func testConnection() async throws -> String {
        let resp = try await authenticated { try await rpc(method: "daemon.info", params: []) }
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
        let resp = try await authenticated {
            try await rpc(
                method: "core.get_torrents_status",
                params: [[String: Any](), ["progress", "download_payload_rate"]]
            )
        }
        // Deluge reports failures in-band (HTTP 200 + an `error` envelope), so
        // dropping them here would render an expired session — or a daemon that
        // lost its connection to the core — as "nothing is downloading": an
        // overlay that quietly dies instead of reporting why.
        if let error = resp["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw DelugeError.actionFailed(message)
        }
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

    /// Runs one authenticated RPC, re-authenticating and retrying it exactly
    /// once if Deluge rejects the session.
    ///
    /// Deluge signals that *in-band*: an expired session cookie comes back as
    /// **HTTP 200** carrying `{"error": {"message": "Not authenticated",
    /// "code": 1}}`, so the HTTP layer never sees a bad status and the response
    /// has to be inspected here. `QueueAggregator` / `DownloadProgressService`
    /// cache this actor for the app's lifetime, so without the retry every
    /// pause/resume failed — and the progress overlay went blank — until
    /// ArrBarr was relaunched.
    ///
    /// Retrying exactly once is deliberate and bounds the recursion: a second
    /// rejection means the password is wrong, not the cookie stale.
    private func authenticated(_ send: () async throws -> [String: Any]) async throws -> [String: Any] {
        try await ensureLoggedIn()
        let generation = sessionGeneration
        let resp = try await send()
        guard let error = resp["error"] as? [String: Any], Self.isAuthError(error) else { return resp }

        invalidateSession(generation: generation)
        // Goes back through `ensureLoggedIn`, so this joins a handshake another
        // caller may already have started rather than racing it.
        try await ensureLoggedIn()
        return try await send()
    }

    /// Deluge's web API reports an expired session as code 1 / "Not
    /// authenticated". Both fields are matched so a daemon that sets only one
    /// still recovers; a false positive costs a single extra login before the
    /// same error surfaces on the retry anyway.
    private static func isAuthError(_ error: [String: Any]) -> Bool {
        if let code = error["code"] as? Int, code == 1 { return true }
        return ((error["message"] as? String) ?? "").lowercased().contains("not authenticated")
    }

    /// Drops the cached session so the next `ensureLoggedIn` re-runs
    /// `auth.login` — unless another caller already logged in since
    /// `generation` was captured, in which case that fresh session is left
    /// untouched.
    private func invalidateSession(generation: Int) {
        guard generation == sessionGeneration else { return }
        loggedIn = false
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
        sessionGeneration += 1
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
