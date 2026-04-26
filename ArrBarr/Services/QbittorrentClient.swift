import Foundation

/// qBittorrent ma session-based auth: najpierw POST /api/v2/auth/login, potem cookies.
/// Trzymamy własną HTTPCookieStorage żeby nie deptać po globalnym storage.
actor QbittorrentClient {
    enum Action {
        case pause, resume, delete

        /// W qBittorrent 5.0+ pause/resume zostały zastąpione przez stop/start.
        /// stop/start istnieją od dawna jako aliasy, więc używamy nowych nazw — bezpieczniejsze.
        var path: String {
            switch self {
            case .pause: return "/api/v2/torrents/stop"
            case .resume: return "/api/v2/torrents/start"
            case .delete: return "/api/v2/torrents/delete"
            }
        }
    }

    private let config: ServiceConfig
    private let session: URLSession
    private let http: HTTPClient
    private var loggedIn = false

    init(config: ServiceConfig) {
        self.config = config
        // Własny URLSession z izolowanym cookie storage, żeby SID qBittorrenta nie mieszał się z niczym.
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage()
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        self.session = URLSession(configuration: configuration)
        self.http = HTTPClient(session: session)
    }

    func perform(_ action: Action, hash: String) async throws {
        try await ensureLoggedIn()
        let url = try http.url(base: config.baseURL, path: action.path)
        var form: [String: String] = ["hashes": hash]
        if action == .delete {
            form["deleteFiles"] = "false"      // tylko z kolejki, nie kasuj plików
        }
        _ = try await http.post(url, headers: refererHeaders(), formBody: form)
    }

    func contains(hash: String) async throws -> Bool {
        let torrents = try await fetchTorrents()
        return torrents.contains { $0.hash.lowercased() == hash.lowercased() }
    }

    private func fetchTorrents() async throws -> [QbitTorrent] {
        try await ensureLoggedIn()
        let url = try http.url(base: config.baseURL, path: "/api/v2/torrents/info")
        let data = try await http.get(url, headers: refererHeaders())
        do {
            return try JSONDecoder().decode([QbitTorrent].self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
    }

    private func ensureLoggedIn() async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        if loggedIn { return }

        let url = try http.url(base: config.baseURL, path: "/api/v2/auth/login")
        let data = try await http.post(
            url,
            headers: refererHeaders(),
            formBody: ["username": config.username, "password": config.password]
        )
        // qBittorrent zwraca "Ok." gdy login OK, "Fails." gdy nie.
        let body = String(data: data, encoding: .utf8) ?? ""
        guard body.contains("Ok") else {
            throw HTTPError.status(401, body: body)
        }
        loggedIn = true
    }

    /// qBittorrent wymaga nagłówka Referer matching base URL od wersji 4.x.
    private func refererHeaders() -> [String: String] {
        ["Referer": config.baseURL]
    }
}
