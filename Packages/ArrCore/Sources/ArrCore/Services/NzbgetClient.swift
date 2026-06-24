import Foundation

public enum NzbgetError: LocalizedError {
    case actionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .actionFailed(let msg): return "NZBGet: \(msg)"
        }
    }
}

public actor NzbgetClient: DownloadProgressSource {
    enum Action { case pause, resume, delete }

    private let config: ServiceConfig
    private let http: HTTPClient

    init(config: ServiceConfig, session: URLSession = .shared) {
        self.config = config
        self.http = HTTPClient(session: session)
    }

    func perform(_ action: Action, nzbId: String) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }

        let command: String = switch action {
        case .pause: "GroupPause"
        case .resume: "GroupResume"
        case .delete: "GroupDelete"
        }

        guard let id = Int(nzbId) else {
            throw NzbgetError.actionFailed("Invalid NZB ID: \(nzbId)")
        }

        let body: [String: Any] = [
            "method": "editqueue",
            "params": [command, "", [id]],
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        let url = try http.url(base: config.baseURL, path: "/jsonrpc")
        let data = try await http.post(url, headers: authHeaders(contentType: "application/json"), body: jsonData)

        if let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = resp["result"] as? Bool, !result {
            throw NzbgetError.actionFailed("Command \(command) returned false")
        }
    }

    func testConnection() async throws -> String {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let body: [String: Any] = ["method": "version", "params": []]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let url = try http.url(base: config.baseURL, path: "/jsonrpc")
        let data = try await http.post(url, headers: authHeaders(contentType: "application/json"), body: jsonData)
        if let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = resp["result"] as? String {
            return "NZBGet \(version)"
        }
        return "OK"
    }

    /// Batch live progress via `listgroups`. `listgroups` carries no per-group
    /// download rate (that's the global `status` method), so only progress is
    /// overlaid — computed from the 64-bit `…SizeLo/Hi` byte fields. Keyed by the
    /// NZBID as a string (the arr's download id for an NZBGet item).
    public func fetchProgress() async throws -> [String: DownloadProgress] {
        guard config.isConfigured else { return [:] }
        let body: [String: Any] = ["method": "listgroups", "params": [0]]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let url = try http.url(base: config.baseURL, path: "/jsonrpc")
        let data = try await http.post(url, headers: authHeaders(contentType: "application/json"), body: jsonData)
        guard let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = resp["result"] as? [[String: Any]] else { return [:] }
        var map: [String: DownloadProgress] = [:]
        for group in groups {
            guard let nzbId = group["NZBID"] as? Int else { continue }
            let total = Self.int64(group, lo: "FileSizeLo", hi: "FileSizeHi")
            let remaining = Self.int64(group, lo: "RemainingSizeLo", hi: "RemainingSizeHi")
            let progress = total > 0 ? Double(total - remaining) / Double(total) : 0
            map[String(nzbId).lowercased()] = DownloadProgress(progress: progress)
        }
        return map
    }

    /// Reassemble a 64-bit byte count from NZBGet's split low/high 32-bit fields.
    private static func int64(_ d: [String: Any], lo: String, hi: String) -> Int64 {
        let low = Int64((d[lo] as? Int) ?? 0) & 0xFFFFFFFF
        let high = Int64((d[hi] as? Int) ?? 0)
        return (high << 32) | low
    }

    private func authHeaders(contentType: String) -> [String: String] {
        var headers = ["Content-Type": contentType]
        if !config.username.isEmpty {
            let cred = "\(config.username):\(config.password)"
            headers["Authorization"] = "Basic \(Data(cred.utf8).base64EncodedString())"
        }
        return headers
    }
}
