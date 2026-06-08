import Foundation

public enum HTTPError: LocalizedError {
    case badURL
    case transport(Error)
    case status(Int, body: String?)
    case decoding(Error)
    case notConfigured
    case missingApiKey
    /// Boundary-check failure: caller tried to add a SearchResult to
    /// a client whose source can't resolve the result's MediaRef
    /// (e.g. a `.tvdb(_)` ref handed to a `.radarr` client). Used to
    /// be silently allowed at the SDK layer and reported as a vague
    /// HTTP 400 from the arr; this case surfaces the mismatch at the
    /// SDK boundary instead.
    case wrongSource(refKind: String, clientSource: String)

    public var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid URL"
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        case .status(let code, _): return "HTTP \(code)"
        case .decoding(let e): return "Decoding error: \(e.localizedDescription)"
        case .notConfigured: return "Service not configured"
        case .missingApiKey: return "API key is missing"
        case .wrongSource(let ref, let src):
            return "Can't add a \(ref) reference via \(src)."
        }
    }
}

public struct HTTPClient {
    /// Per-request timeout. arr endpoints return small JSON over the LAN, so
    /// 15s of inactivity is generous — but it bounds how long a hung/restarting
    /// arr can stall a refresh. Without it, requests inherit URLSession's 60s
    /// default and one stalled arr freezes the whole queue refresh (the
    /// aggregator awaits all four arrs together) for a minute-plus.
    public static let requestTimeout: TimeInterval = 15

    let session: URLSession
    /// Per-request timeout for this client. Defaults to the short
    /// refresh-safe `requestTimeout`; the chat-tool / search clients raise it
    /// (indexer searches legitimately take longer than the refresh budget).
    let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = HTTPClient.requestTimeout) {
        self.session = session
        self.timeout = timeout
    }

    func url(base: String, path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: base) else { throw HTTPError.badURL }
        let normalizedBasePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = normalizedBasePath + path
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        guard let url = components.url else { throw HTTPError.badURL }
        return url
    }

    func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await perform(req)
    }

    func post(_ url: URL, headers: [String: String] = [:], formBody: [String: String]? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let formBody {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.encodeForm(formBody).data(using: .utf8)
        }
        return try await perform(req)
    }

    func post(_ url: URL, headers: [String: String] = [:], body: Data) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return try await perform(req)
    }

    func delete(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await perform(req)
    }

    func put(_ url: URL, headers: [String: String] = [:], body: Data) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return try await perform(req)
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        var req = req
        // Bound every request so a hung/restarting arr can't stall a refresh
        // for URLSession's 60s default. See `timeout` / `requestTimeout`.
        req.timeoutInterval = timeout
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            // Don't wrap cancellation as a transport "error" — it's a normal
            // task teardown (pull-to-refresh released, overlapping refresh).
            // Rethrown bare so callers can recognise and ignore it.
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw HTTPError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.status(-1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return data
    }

    static func encodeForm(_ dict: [String: String]) -> String {
        dict.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
