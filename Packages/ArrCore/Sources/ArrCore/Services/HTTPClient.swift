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
            let detail = Self.serverMessage(from: body)
            // …except on 401/403, where Servarr answers with an *empty* body:
            // a wrong or missing API key renders as a bare "HTTP 401" that
            // names neither the cause nor the fix. Say both, and keep any
            // detail the service did send (download clients usually do).
            if code == 401 || code == 403 {
                let hint = String(
                    localized: "Authentication failed. Check the API key or password in Settings.",
                    bundle: .module
                )
                if let detail { return "HTTP \(code): \(hint) (\(detail))" }
                return "HTTP \(code): \(hint)"
            }
            if let detail {
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
        // Strip *every* trailing slash, not just one: a base pasted as
        // "https://host/sonarr//" would otherwise join into a path with a
        // double slash, which reverse proxies in front of an arr can 404.
        var normalizedBasePath = components.path
        while normalizedBasePath.hasSuffix("/") { normalizedBasePath.removeLast() }
        components.path = normalizedBasePath + path
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        // URLComponents leaves "+" literal in the query (it's a legal sub-delim),
        // but ASP.NET — which every arr runs on — decodes a literal "+" as a
        // space, so searching "Disney+", "Apple TV+" or "C++" would silently
        // query the wrong term. Re-encode just that one character on the
        // already-encoded query, leaving everything URLComponents got right
        // (space, "&", "=", unicode) exactly as it is.
        if let encodedQuery = components.percentEncodedQuery {
            components.percentEncodedQuery = encodedQuery.replacingOccurrences(of: "+", with: "%2B")
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

    /// Characters an `application/x-www-form-urlencoded` field may carry
    /// literally — RFC 3986's unreserved set. Everything else is
    /// percent-encoded, non-ASCII included (Foundation escapes non-ASCII
    /// bytes regardless of the allowed set, so "é" still becomes %C3%A9).
    ///
    /// Deliberately NOT `.urlQueryAllowed`: that set *permits* "&", "=" and
    /// "+", so a qBittorrent password like `p&ss=w+rd` used to be spliced
    /// into extra form fields ("password=p", "ss=w+rd") and the login failed
    /// with an unexplained 403 loop.
    private static let formFieldAllowed: CharacterSet =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func encodeForm(_ dict: [String: String]) -> String {
        // Sorted by key so the body is deterministic: field order means
        // nothing to a form parser, but it makes this testable.
        dict.sorted { $0.key < $1.key }.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: Self.formFieldAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: Self.formFieldAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
