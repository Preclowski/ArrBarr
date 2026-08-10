import Foundation

public enum NzbgetError: LocalizedError {
    case actionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .actionFailed(let msg): return "NZBGet: \(msg)"
        }
    }
}

public actor NzbgetClient: DownloadProgressSource, DownloadAddSource {
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

        // A body we can't read is a failure, not a silent success — an NZBGet
        // behind a reverse proxy answers 200 with an HTML login page.
        guard let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NzbgetError.actionFailed(
                String(localized: "The server sent an unreadable response.", bundle: .module)
            )
        }
        // A JSON-RPC-*level* failure comes back as HTTP 200 with an `error`
        // member and NO `result` key at all, so the `result == false` check
        // below never fires for it and a rejected command used to report
        // success. Check `error` first and surface the server's own message —
        // it's the only text that says what actually went wrong. Matching on
        // the concrete shapes (struct, non-empty string) also keeps a legal
        // JSON-RPC `"error": null` on success from tripping this.
        if let error = resp["error"] as? [String: Any] {
            let detail = (error["message"] as? String) ?? (error["name"] as? String)
            throw NzbgetError.actionFailed(detail ?? Self.rejectionMessage(command))
        }
        if let error = resp["error"] as? String, !error.isEmpty {
            throw NzbgetError.actionFailed(error)
        }
        // `editqueue` answers a bare `false` when the edit didn't apply, with
        // no message anywhere — say what that usually means instead.
        if let result = resp["result"] as? Bool, !result {
            throw NzbgetError.actionFailed(Self.rejectionMessage(command))
        }
    }

    /// Upload an .nzb via `append`, which takes the file base64-encoded inside
    /// the JSON-RPC body — no multipart involved.
    ///
    /// The positional parameter list is NZBGet's v13+ signature and every slot
    /// has to be present in order: filename, content, category, priority,
    /// addToTop, addPaused, dupeKey, dupeScore, dupeMode, postParameters.
    /// `append` answers with the new NZBID, or `0` when it refused the file.
    public func add(_ drop: DownloadDrop, category: String?, paused: Bool) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        guard case .file(let data, let filename) = drop.content else {
            // Unreachable in practice (a magnet never resolves to usenet), but
            // an explicit failure beats silently doing nothing.
            throw NzbgetError.actionFailed(
                String(localized: "NZBGet can only take .nzb files.", bundle: .module)
            )
        }

        let body: [String: Any] = [
            "method": "append",
            "params": [
                filename,
                data.base64EncodedString(),
                category ?? "",
                0,                  // priority — normal
                false,              // addToTop
                paused,
                "",                 // dupeKey
                0,                  // dupeScore
                "SCORE",            // dupeMode
                [[String: Any]](),  // postParameters
            ],
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let url = try http.url(base: config.baseURL, path: "/jsonrpc")
        let data2 = try await http.post(url, headers: authHeaders(contentType: "application/json"), body: jsonData)

        guard let resp = try? JSONSerialization.jsonObject(with: data2) as? [String: Any] else {
            throw NzbgetError.actionFailed(
                String(localized: "The server sent an unreadable response.", bundle: .module)
            )
        }
        if let error = resp["error"] as? [String: Any] {
            let detail = (error["message"] as? String) ?? (error["name"] as? String)
            throw NzbgetError.actionFailed(detail ?? Self.rejectionMessage("append"))
        }
        if let error = resp["error"] as? String, !error.isEmpty {
            throw NzbgetError.actionFailed(error)
        }
        // A refused append is a zero id, not an error member.
        guard let id = resp["result"] as? Int, id > 0 else {
            throw NzbgetError.actionFailed(
                String(localized: "NZBGet rejected the file.", bundle: .module)
            )
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

    /// Wording for a command NZBGet refused without explaining why: a bare
    /// `result: false`, or an `error` member carrying no message.
    private static func rejectionMessage(_ command: String) -> String {
        String(
            format: String(
                localized: "The server rejected %@ — the download may have already finished or been removed.",
                bundle: .module
            ),
            command
        )
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
