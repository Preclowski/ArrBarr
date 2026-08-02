import Foundation

public actor QbittorrentClient: DownloadProgressSource {
    enum Action {
        case pause, resume, delete, forceStart

        var path: String {
            switch self {
            case .pause: return "/api/v2/torrents/stop"
            case .resume: return "/api/v2/torrents/start"
            case .delete: return "/api/v2/torrents/delete"
            // Force-start bypasses qBittorrent's own queueing limit and begins
            // downloading immediately — the "continue" action for a queued torrent.
            case .forceStart: return "/api/v2/torrents/setForceStart"
            }
        }
    }

    private let config: ServiceConfig
    private let session: URLSession
    private let http: HTTPClient
    /// Whether `/auth/login` has established a live SID cookie. Cleared again
    /// by `invalidateSession(generation:)` when the WebUI rejects a request:
    /// qBittorrent expires the session after an hour of inactivity (and drops
    /// every session on restart), while this actor is cached for the app's
    /// lifetime.
    private var loggedIn = false
    /// Bumped by every successful login. A request captures the generation it
    /// was sent under, so a rejection can only invalidate *that* session — when
    /// a burst of stale requests all 403 at once, the first one re-logs-in and
    /// the rest retry on its fresh session instead of tearing it back down.
    private var sessionGeneration = 0
    /// In-flight login handshake, shared so a burst of concurrent actions
    /// awaits ONE `/auth/login` instead of each racing its own (a later SID
    /// cookie could otherwise clobber an earlier one → 403).
    private var loginTask: Task<Void, Error>?

    init(config: ServiceConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            // qBittorrent's password-login flow authenticates via
            // /api/v2/auth/login and tracks the session with a SID cookie, so
            // the session needs cookie storage. (API-key mode skips login and
            // doesn't need the cookie, but sharing one session is harmless.)
            let configuration = HTTPClient.uncachedConfiguration()
            configuration.httpCookieStorage = HTTPCookieStorage()
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
            self.session = URLSession(configuration: configuration)
        }
        self.http = HTTPClient(session: self.session)
    }

    /// qBittorrent 5.x accepts either a username/password login or an API
    /// key. We treat an empty username as "API-key mode": the `password`
    /// field carries the key, sent as `Authorization: Bearer <key>` on every
    /// request with no login handshake. A non-empty username uses the classic
    /// `/api/v2/auth/login` + SID-cookie flow.
    private var usesApiKey: Bool { config.username.isEmpty }

    func perform(_ action: Action, hash: String) async throws {
        var form: [String: String] = ["hashes": hash]
        if action == .delete {
            form["deleteFiles"] = "false"
        }
        if action == .forceStart {
            form["value"] = "true"
        }
        _ = try await authenticated {
            let url = try http.url(base: config.baseURL, path: action.path)
            return try await http.post(url, headers: authHeaders(), formBody: form)
        }
    }

    func testConnection() async throws -> String {
        let data = try await authenticated {
            let url = try http.url(base: config.baseURL, path: "/api/v2/app/version")
            return try await http.get(url, headers: authHeaders())
        }
        let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? "OK" : "qBittorrent \(version)"
    }

    func contains(hash: String) async throws -> Bool {
        let torrents = try await fetchTorrents()
        return torrents.contains { $0.hash.lowercased() == hash.lowercased() }
    }

    /// Batch live progress for every torrent, keyed by lowercased hash (the arr
    /// stores the same hash upper-cased, so the overlay lowercases both sides).
    /// Reuses the existing `/torrents/info` fetch — `progress` + `dlspeed` are
    /// already in the payload, just unused until now.
    public func fetchProgress() async throws -> [String: DownloadProgress] {
        let torrents = try await fetchTorrents()
        return Dictionary(
            torrents.map { ($0.hash.lowercased(), DownloadProgress(progress: $0.progress, downloadSpeed: $0.dlspeed)) },
            uniquingKeysWith: { _, new in new }
        )
    }

    private func fetchTorrents() async throws -> [QbitTorrent] {
        let data = try await authenticated {
            let url = try http.url(base: config.baseURL, path: "/api/v2/torrents/info")
            return try await http.get(url, headers: authHeaders())
        }
        do {
            return try JSONDecoder().decode([QbitTorrent].self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
    }

    /// Runs one authenticated request, re-authenticating and retrying it
    /// exactly once if qBittorrent rejects the session.
    ///
    /// The WebUI session expires after an hour of inactivity and dies with any
    /// server restart, but `QueueAggregator` / `DownloadProgressService` cache
    /// this actor for the app's lifetime — so without the retry every
    /// pause/resume/force-start failed with a bare HTTP 403 (and the progress
    /// overlay silently went blank) until ArrBarr was relaunched, while the
    /// health probe — which builds a *fresh* client each minute and logs in
    /// fine — kept the Settings dot green.
    ///
    /// Retrying exactly once is deliberate and bounds the recursion: a second
    /// rejection means wrong credentials, not an expired cookie, and has to
    /// surface to the user.
    private func authenticated(_ send: () async throws -> Data) async throws -> Data {
        try await ensureLoggedIn()
        // API-key mode authenticates per request via the Bearer header — there
        // is no session to refresh, so a 403 means the key itself is wrong.
        if usesApiKey { return try await send() }

        let generation = sessionGeneration
        do {
            return try await send()
        } catch let error as HTTPError where Self.isAuthFailure(error) {
            invalidateSession(generation: generation)
            // Goes back through `ensureLoggedIn`, so this joins a handshake
            // another caller may already have started rather than racing it.
            try await ensureLoggedIn()
            return try await send()
        }
    }

    /// qBittorrent answers an expired or missing SID with 403; a reverse proxy
    /// doing the authentication in front of it answers 401.
    private static func isAuthFailure(_ error: HTTPError) -> Bool {
        guard case .status(let code, _) = error else { return false }
        return code == 401 || code == 403
    }

    /// Drops the cached session so the next `ensureLoggedIn` re-runs the
    /// handshake — unless another caller already logged in since `generation`
    /// was captured, in which case that fresh session is left untouched.
    private func invalidateSession(generation: Int) {
        guard generation == sessionGeneration else { return }
        loggedIn = false
    }

    private func ensureLoggedIn() async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        // API-key mode authenticates per-request via the Bearer header, so
        // there's no session login to establish.
        if usesApiKey || loggedIn { return }
        // Join an already-running handshake rather than starting a second one.
        if let task = loginTask { try await task.value; return }

        let task = Task { try await self.performLogin() }
        loginTask = task
        defer { loginTask = nil }
        try await task.value
    }

    private func performLogin() async throws {
        let url = try http.url(base: config.baseURL, path: "/api/v2/auth/login")
        let data = try await http.post(
            url,
            headers: authHeaders(),
            formBody: ["username": config.username, "password": config.password]
        )
        let body = String(data: data, encoding: .utf8) ?? ""
        guard body.contains("Ok") else {
            throw HTTPError.status(401, body: body)
        }
        loggedIn = true
        sessionGeneration += 1
    }

    /// Always sends `Referer` (qBittorrent's CSRF policy rejects requests
    /// without it). In API-key mode it additionally carries the key as a
    /// Bearer token.
    private func authHeaders() -> [String: String] {
        var headers = ["Referer": config.baseURL]
        if usesApiKey, !config.password.isEmpty {
            headers["Authorization"] = "Bearer \(config.password)"
        }
        return headers
    }
}
