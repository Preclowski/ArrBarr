import Foundation

public enum SabnzbdError: LocalizedError {
    case actionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .actionFailed(let msg): return "SABnzbd: \(msg)"
        }
    }
}

private struct SabActionResponse: Decodable {
    let status: Bool?
    let error: String?
}

public actor SabnzbdClient: DownloadProgressSource {
    enum Action: String { case pause, resume, delete }

    private let config: ServiceConfig
    private let http: HTTPClient

    init(config: ServiceConfig, session: URLSession = .shared) {
        self.config = config
        self.http = HTTPClient(session: session)
    }

    func perform(_ action: Action, nzoId: String) async throws {
        guard config.isConfigured, !config.apiKey.isEmpty else { throw HTTPError.notConfigured }

        let url = try http.url(
            base: config.baseURL,
            path: "/api",
            query: [
                URLQueryItem(name: "mode", value: "queue"),
                URLQueryItem(name: "name", value: action.rawValue),
                URLQueryItem(name: "value", value: nzoId),
                URLQueryItem(name: "output", value: "json"),
                URLQueryItem(name: "apikey", value: config.apiKey),
            ]
        )
        let data = try await http.get(url)
        // A body we can't decode is a failure, not a silent success: `try?`
        // here reported the action as done for anything that wasn't SAB JSON
        // at all (a reverse-proxy login page, a truncated reply) while the
        // queue never moved. Same handling as `fetchSlots` below.
        let resp: SabActionResponse
        do {
            resp = try JSONDecoder().decode(SabActionResponse.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
        if resp.status == false {
            throw SabnzbdError.actionFailed(resp.error ?? "Unknown SABnzbd error")
        }
    }

    func contains(nzoId: String) async throws -> Bool {
        let slots = try await fetchSlots()
        return slots.contains { $0.nzo_id == nzoId }
    }

    /// Batch live progress for every queued nzb, keyed by lowercased nzo id (to
    /// match `QueueItem.downloadId` the same case-insensitive way as torrents).
    /// `percentage` is SAB's own "%" string; SAB exposes no reliable per-slot
    /// speed, so `downloadSpeed` stays nil.
    public func fetchProgress() async throws -> [String: DownloadProgress] {
        let slots = try await fetchSlots()
        return Dictionary(
            slots.map { ($0.nzo_id.lowercased(), DownloadProgress(progress: (Double($0.percentage) ?? 0) / 100)) },
            uniquingKeysWith: { _, new in new }
        )
    }

func testConnection() async throws -> String {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        // Probe an AUTH-GATED call (`mode=queue`), not `mode=version`. SABnzbd
        // exempts only `version`/`auth` from the API key, so `version` returns
        // 200 even with a wrong/empty key — a false "connected". `queue`
        // requires the key and returns `{"status": false, "error": "API Key
        // Incorrect"}` when it's wrong, which we surface as a failure.
        let url = try http.url(
            base: config.baseURL,
            path: "/api",
            query: [
                URLQueryItem(name: "mode", value: "queue"),
                URLQueryItem(name: "output", value: "json"),
                URLQueryItem(name: "apikey", value: config.apiKey),
            ]
        )
        let data = try await http.get(url)
        if let resp = try? JSONDecoder().decode(SabActionResponse.self, from: data),
           resp.status == false {
            throw SabnzbdError.actionFailed(resp.error ?? "API Key Incorrect")
        }
        struct QueueVersion: Decodable {
            struct Queue: Decodable { let version: String? }
            let queue: Queue?
        }
        let v = try? JSONDecoder().decode(QueueVersion.self, from: data)
        return v?.queue?.version.map { "SABnzbd \($0)" } ?? "OK"
    }

    private func fetchSlots() async throws -> [SabSlot] {
        guard config.isConfigured, !config.apiKey.isEmpty else { throw HTTPError.notConfigured }

        let url = try http.url(
            base: config.baseURL,
            path: "/api",
            query: [
                URLQueryItem(name: "mode", value: "queue"),
                URLQueryItem(name: "output", value: "json"),
                URLQueryItem(name: "apikey", value: config.apiKey),
            ]
        )
        let data = try await http.get(url)
        do {
            let resp = try JSONDecoder().decode(SabQueueResponse.self, from: data)
            return resp.queue.slots
        } catch {
            throw HTTPError.decoding(error)
        }
    }
}
