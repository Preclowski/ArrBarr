import Foundation

enum RtorrentError: LocalizedError {
    case actionFailed(String)
    var errorDescription: String? {
        switch self {
        case .actionFailed(let msg): return "rTorrent: \(msg)"
        }
    }
}

actor RtorrentClient {
    enum Action { case pause, resume, delete }

    private let config: ServiceConfig
    private let http: HTTPClient

    init(config: ServiceConfig, session: URLSession = .shared) {
        self.config = config
        self.http = HTTPClient(session: session)
    }

    func perform(_ action: Action, hash: String) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }

        let methodName: String = switch action {
        case .pause: "d.stop"
        case .resume: "d.start"
        case .delete: "d.erase"
        }

        let xml = xmlrpcCall(method: methodName, stringParam: hash)
        let url = try http.url(base: config.baseURL, path: "")
        let data = try await http.post(url, headers: authHeaders(), body: Data(xml.utf8))

        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("<fault>") {
            throw RtorrentError.actionFailed("XMLRPC fault in response to \(methodName)")
        }
    }

    func testConnection() async throws -> String {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>\
        <methodCall>\
        <methodName>system.client_version</methodName>\
        <params></params>\
        </methodCall>
        """
        let url = try http.url(base: config.baseURL, path: "")
        let data = try await http.post(url, headers: authHeaders(), body: Data(xml.utf8))
        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("<fault>") {
            throw RtorrentError.actionFailed("XMLRPC fault during version check")
        }
        // Crude extraction of <string>X</string>
        if let r = body.range(of: "<string>"),
           let end = body.range(of: "</string>", range: r.upperBound..<body.endIndex) {
            let v = String(body[r.upperBound..<end.lowerBound])
            return "rTorrent \(v)"
        }
        return "OK"
    }

    private func xmlrpcCall(method: String, stringParam: String) -> String {
        let escaped = stringParam
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>\
        <methodCall>\
        <methodName>\(method)</methodName>\
        <params><param><value><string>\(escaped)</string></value></param></params>\
        </methodCall>
        """
    }

    private func authHeaders() -> [String: String] {
        var headers = ["Content-Type": "text/xml"]
        if !config.username.isEmpty {
            let cred = "\(config.username):\(config.password)"
            headers["Authorization"] = "Basic \(Data(cred.utf8).base64EncodedString())"
        }
        return headers
    }
}
