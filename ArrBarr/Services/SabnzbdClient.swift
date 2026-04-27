import Foundation

enum SabnzbdError: LocalizedError {
    case actionFailed(String)
    var errorDescription: String? {
        switch self {
        case .actionFailed(let msg): return "SABnzbd: \(msg)"
        }
    }
}

private struct SabActionResponse: Decodable {
    let status: Bool?
    let error: String?
}

actor SabnzbdClient {
    enum Action: String { case pause, resume, delete }

    private let config: ServiceConfig
    private let http = HTTPClient()

    init(config: ServiceConfig) {
        self.config = config
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
        let resp = try? JSONDecoder().decode(SabActionResponse.self, from: data)
        if resp?.status == false {
            throw SabnzbdError.actionFailed(resp?.error ?? "Unknown SABnzbd error")
        }
    }

    func contains(nzoId: String) async throws -> Bool {
        let slots = try await fetchSlots()
        return slots.contains { $0.nzo_id == nzoId }
    }

    func testConnection() async throws -> String {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard !config.apiKey.isEmpty else { throw HTTPError.missingApiKey }
        let url = try http.url(
            base: config.baseURL,
            path: "/api",
            query: [
                URLQueryItem(name: "mode", value: "version"),
                URLQueryItem(name: "output", value: "json"),
                URLQueryItem(name: "apikey", value: config.apiKey),
            ]
        )
        let data = try await http.get(url)
        struct Version: Decodable { let version: String? }
        let v = try? JSONDecoder().decode(Version.self, from: data)
        return v?.version.map { "SABnzbd \($0)" } ?? "OK"
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
