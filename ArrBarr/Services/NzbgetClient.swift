import Foundation

enum NzbgetError: LocalizedError {
    case actionFailed(String)
    var errorDescription: String? {
        switch self {
        case .actionFailed(let msg): return "NZBGet: \(msg)"
        }
    }
}

actor NzbgetClient {
    enum Action { case pause, resume, delete }

    private let config: ServiceConfig
    private let http: HTTPClient

    init(config: ServiceConfig, session: URLSession = .shared) {
        self.config = config
        self.http = HTTPClient(session: session)
    }

    func perform(_ action: Action, nzbId: String) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }

        let command: String = switch action {
        case .pause: "GroupPause"
        case .resume: "GroupResume"
        case .delete: "GroupDelete"
        }

        guard let id = Int(nzbId) else {
            throw NzbgetError.actionFailed("Invalid NZB ID: \(nzbId)")
        }

        let body: [String: Any] = [
            "method": "editqueue",
            "params": [command, "", [id]],
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        let url = try http.url(base: config.baseURL, path: "/jsonrpc")
        let data = try await http.post(url, headers: authHeaders(contentType: "application/json"), body: jsonData)

        if let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = resp["result"] as? Bool, !result {
            throw NzbgetError.actionFailed("Command \(command) returned false")
        }
    }

    func testConnection() async throws -> String {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let body: [String: Any] = ["method": "version", "params": []]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let url = try http.url(base: config.baseURL, path: "/jsonrpc")
        let data = try await http.post(url, headers: authHeaders(contentType: "application/json"), body: jsonData)
        if let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = resp["result"] as? String {
            return "NZBGet \(version)"
        }
        return "OK"
    }

    private func authHeaders(contentType: String) -> [String: String] {
        var headers = ["Content-Type": contentType]
        if !config.username.isEmpty {
            let cred = "\(config.username):\(config.password)"
            headers["Authorization"] = "Basic \(Data(cred.utf8).base64EncodedString())"
        }
        return headers
    }
}
