import Foundation

public actor QbittorrentClient {
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
    private var loggedIn = false

    init(config: ServiceConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            // qBittorrent's password-login flow authenticates via
            // /api/v2/auth/login and tracks the session with a SID cookie, so
            // the session needs cookie storage. (API-key mode skips login and
            // doesn't need the cookie, but sharing one session is harmless.)
            let configuration = URLSessionConfiguration.default
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
        try await ensureLoggedIn()
        let url = try http.url(base: config.baseURL, path: action.path)
        var form: [String: String] = ["hashes": hash]
        if action == .delete {
            form["deleteFiles"] = "false"
        }
        if action == .forceStart {
            form["value"] = "true"
        }
        _ = try await http.post(url, headers: authHeaders(), formBody: form)
    }

    func testConnection() async throws -> String {
        try await ensureLoggedIn()
        let url = try http.url(base: config.baseURL, path: "/api/v2/app/version")
        let data = try await http.get(url, headers: authHeaders())
        let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? "OK" : "qBittorrent \(version)"
    }

    func contains(hash: String) async throws -> Bool {
        let torrents = try await fetchTorrents()
        return torrents.contains { $0.hash.lowercased() == hash.lowercased() }
    }

    private func fetchTorrents() async throws -> [QbitTorrent] {
        try await ensureLoggedIn()
        let url = try http.url(base: config.baseURL, path: "/api/v2/torrents/info")
        let data = try await http.get(url, headers: authHeaders())
        do {
            return try JSONDecoder().decode([QbitTorrent].self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
    }

    private func ensureLoggedIn() async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        // API-key mode authenticates per-request via the Bearer header, so
        // there's no session login to establish.
        if usesApiKey || loggedIn { return }

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
