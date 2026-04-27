import Foundation

enum TransmissionError: LocalizedError {
    case actionFailed(String)
    case noSessionId
    var errorDescription: String? {
        switch self {
        case .actionFailed(let msg): return "Transmission: \(msg)"
        case .noSessionId: return "Transmission: failed to obtain session ID"
        }
    }
}

actor TransmissionClient {
    enum Action { case pause, resume, delete }

    private let config: ServiceConfig
    private let session: URLSession
    private let http: HTTPClient
    private var sessionId: String?

    init(config: ServiceConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        self.http = HTTPClient(session: session)
    }

    func perform(_ action: Action, hash: String) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }

        let url = try http.url(base: config.baseURL, path: "/transmission/rpc")
        let body = rpcBody(action: action, hash: hash)
        let data = try await rpcRequest(url: url, body: body)

        if let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = resp["result"] as? String, result != "success" {
            throw TransmissionError.actionFailed(result)
        }
    }

    private func rpcRequest(url: URL, body: Data, retried: Bool = false) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        if !config.username.isEmpty {
            let cred = "\(config.username):\(config.password)"
            request.setValue("Basic \(Data(cred.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "X-Transmission-Session-Id")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPError.transport(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.status(-1, body: nil)
        }

        if httpResponse.statusCode == 409, !retried {
            guard let newId = httpResponse.value(forHTTPHeaderField: "X-Transmission-Session-Id") else {
                throw TransmissionError.noSessionId
            }
            sessionId = newId
            return try await rpcRequest(url: url, body: body, retried: true)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HTTPError.status(httpResponse.statusCode, body: String(data: data, encoding: .utf8))
        }

        return data
    }

    private func rpcBody(action: Action, hash: String) -> Data {
        let method: String
        var arguments: [String: Any] = ["ids": [hash]]

        switch action {
        case .pause: method = "torrent-stop"
        case .resume: method = "torrent-start"
        case .delete:
            method = "torrent-remove"
            arguments["delete-local-data"] = false
        }

        let body: [String: Any] = ["method": method, "arguments": arguments]
        return try! JSONSerialization.data(withJSONObject: body)
    }
}
