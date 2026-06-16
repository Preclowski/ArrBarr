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
        case .status(let code, let body):
            // arr APIs return the real reason in the body (e.g. Sonarr's
            // "This series has already been added", an invalid quality
            // profile, or a missing root folder). Surfacing just "HTTP 400"
            // hides all of that. Parse the server message and append it.
            if let detail = Self.serverMessage(from: body) {
                return "HTTP \(code): \(detail)"
            }
            return "HTTP \(code)"
        case .decoding(let e): return "Decoding error: \(e.localizedDescription)"
        case .notConfigured: return "Service not configured"
        case .missingApiKey: return "API key is missing"
        case .wrongSource(let ref, let src):
            return "Can't add a \(ref) reference via \(src)."
        }
    }

    /// Extract a human-readable reason from an arr error-response body.
    /// arr stacks return validation failures in several shapes:
    ///   • Servarr array: `[{ "errorMessage": "…", "propertyName": "…" }]`
    ///   • Servarr object: `{ "message": "…" }`
    ///   • ASP.NET ProblemDetails: `{ "title": "…", "errors": { "field": ["…"] } }`
    /// Falls back to the trimmed raw body so nothing useful is ever dropped.
    /// Returns nil when there's nothing to show.
    static func serverMessage(from body: String?) -> String? {
        guard let body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            // Servarr validation array: [{ "errorMessage": "…" }, …]
            if let arr = json as? [[String: Any]] {
                let messages = arr.compactMap { stringValue(in: $0) }
                if !messages.isEmpty { return messages.joined(separator: "; ") }
            }
            if let obj = json as? [String: Any] {
                // ASP.NET ProblemDetails: { "errors": { "field": ["msg", …] } }
                if let errors = obj["errors"] as? [String: Any] {
                    let messages = errors.values.flatMap { value -> [String] in
                        if let list = value as? [String] { return list }
                        if let one = value as? String { return [one] }
                        return []
                    }
                    if !messages.isEmpty { return messages.joined(separator: "; ") }
                }
                // Single-object forms: message / errorMessage / title / detail.
                if let msg = stringValue(in: obj) { return msg }
            }
        }
        // Non-JSON body (plain text / HTML error page): cap length so a stray
        // HTML dump doesn't swamp the UI.
        return String(trimmed.prefix(300))
    }

    /// Pull the first present message-bearing string out of one JSON object,
    /// trying the keys the various arr / ASP.NET error shapes use.
    private static func stringValue(in obj: [String: Any]) -> String? {
        for key in ["errorMessage", "message", "title", "detail", "error"] {
            if let s = obj[key] as? String,
               !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s
            }
        }
        return nil
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
