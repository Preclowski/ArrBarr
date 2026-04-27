import Foundation

enum DelugeError: LocalizedError {
    case authFailed
    case actionFailed(String)
    var errorDescription: String? {
        switch self {
        case .authFailed: return "Deluge: authentication failed"
        case .actionFailed(let msg): return "Deluge: \(msg)"
        }
    }
}

actor DelugeClient {
    enum Action { case pause, resume, delete }

    private let config: ServiceConfig
    private let session: URLSession
    private let http: HTTPClient
    private var loggedIn = false
    private var requestId = 0

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

    private func ensureLoggedIn() async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        if loggedIn { return }

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
