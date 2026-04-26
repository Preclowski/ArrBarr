import Foundation

/// Klient do SABnzbd. Endpoint /api z parametrami query (mode/name/value/apikey).
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
        _ = try await http.get(url)
    }

    /// Sprawdzenie czy nzo_id istnieje w kolejce SAB-a (do diagnostyki).
    func contains(nzoId: String) async throws -> Bool {
        let slots = try await fetchSlots()
        return slots.contains { $0.nzo_id == nzoId }
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
