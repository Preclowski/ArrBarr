import Foundation

/// Common HTTP+auth boilerplate shared by every *arr* REST client
/// (Sonarr/Radarr/Lidarr/Whisparr/...). Each conforming type supplies
/// its `config` and `apiBase` ("/api/v3" for Sonarr/Radarr, "/api/v1"
/// for Lidarr); the default GET/POST/DELETE helpers handle URL
/// construction, X-Api-Key header injection, and JSON decoding.
public protocol ArrAPIClient: Sendable {
    var config: ServiceConfig { get }
    /// API root path, e.g. "/api/v3" or "/api/v1".
    var apiBase: String { get }
    var http: HTTPClient { get }
}

extension ArrAPIClient {
    /// Standard auth header for every request to an arr.
    var apiHeaders: [String: String] {
        ["X-Api-Key": config.apiKey]
    }

    /// GET <apiBase><path> and decode the JSON body as T.
    func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)\(path)", query: query)
        let data = try await http.get(url, headers: apiHeaders)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Same as `get` but tolerates decode failures with a fallback (used by
    /// some library-listing paths that today silently return [] on decode
    /// errors to keep the UI happy). New code should prefer plain `get`.
    func getOrDefault<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], default fallback: T) async throws -> T {
        guard config.isConfigured else { return fallback }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)\(path)", query: query)
        let data = try await http.get(url, headers: apiHeaders)
        return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
    }

    /// POST a JSON body to <apiBase><path>. Returns the raw response data.
    @discardableResult
    func post(_ path: String, body: [String: Any]) async throws -> Data {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)\(path)")
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await http.post(
            url,
            headers: apiHeaders.merging(["Content-Type": "application/json"]) { $1 },
            body: data
        )
    }

    /// DELETE <apiBase><path>?key=val&...
    func delete(_ path: String, query: [URLQueryItem] = []) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let url = try http.url(base: config.baseURL, path: "\(apiBase)\(path)", query: query)
        _ = try await http.delete(url, headers: apiHeaders)
    }
}
