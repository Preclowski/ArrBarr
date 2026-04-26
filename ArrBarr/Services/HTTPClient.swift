import Foundation

enum HTTPError: LocalizedError {
    case badURL
    case transport(Error)
    case status(Int, body: String?)
    case decoding(Error)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid URL"
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        case .status(let code, _): return "HTTP \(code)"
        case .decoding(let e): return "Decoding error: \(e.localizedDescription)"
        case .notConfigured: return "Service not configured"
        }
    }
}

/// Cienki wrapper na URLSession ułatwiający budowanie requestów do API *arr/SAB/qBit.
struct HTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Zbuduj URL z `base` + `path` + query items.
    func url(base: String, path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: base) else { throw HTTPError.badURL }
        // Append path bezpiecznie nawet jeśli base ma trailing slash.
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

    private func perform(_ req: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
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
