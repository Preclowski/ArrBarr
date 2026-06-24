import Foundation

public enum RtorrentError: LocalizedError {
    case actionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .actionFailed(let msg): return "rTorrent: \(msg)"
        }
    }
}

public actor RtorrentClient: DownloadProgressSource {
    enum Action { case pause, resume, delete }

    private let config: ServiceConfig
    private let http: HTTPClient

    init(config: ServiceConfig, session: URLSession = .shared) {
        self.config = config
        self.http = HTTPClient(session: session)
    }

    func perform(_ action: Action, hash: String) async throws {
        guard config.isConfigured else { throw HTTPError.notConfigured }

        let methodName: String = switch action {
        case .pause: "d.stop"
        case .resume: "d.start"
        case .delete: "d.erase"
        }

        let xml = xmlrpcCall(method: methodName, stringParam: hash)
        let url = try http.url(base: config.baseURL, path: "")
        let data = try await http.post(url, headers: authHeaders(), body: Data(xml.utf8))

        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("<fault>") {
            throw RtorrentError.actionFailed("XMLRPC fault in response to \(methodName)")
        }
    }

    func testConnection() async throws -> String {
        guard config.isConfigured else { throw HTTPError.notConfigured }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>\
        <methodCall>\
        <methodName>system.client_version</methodName>\
        <params></params>\
        </methodCall>
        """
        let url = try http.url(base: config.baseURL, path: "")
        let data = try await http.post(url, headers: authHeaders(), body: Data(xml.utf8))
        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("<fault>") {
            throw RtorrentError.actionFailed("XMLRPC fault during version check")
        }
        // Crude extraction of <string>X</string>
        if let r = body.range(of: "<string>"),
           let end = body.range(of: "</string>", range: r.upperBound..<body.endIndex) {
            let v = String(body[r.upperBound..<end.lowerBound])
            return "rTorrent \(v)"
        }
        return "OK"
    }

    /// Batch live progress via `d.multicall2("", "main", d.hash=,
    /// d.completed_bytes=, d.size_bytes=, d.down.rate=)`. The XML-RPC response
    /// lists those four values per torrent in request order, so we pull the leaf
    /// `<string>`/`<i8>`/`<i4>` values in document order and chunk them by four.
    /// `d.hash` is upper-case hex → lowercased to match the arr's download id.
    public func fetchProgress() async throws -> [String: DownloadProgress] {
        guard config.isConfigured else { return [:] }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>\
        <methodCall><methodName>d.multicall2</methodName><params>\
        <param><value><string></string></value></param>\
        <param><value><string>main</string></value></param>\
        <param><value><string>d.hash=</string></value></param>\
        <param><value><string>d.completed_bytes=</string></value></param>\
        <param><value><string>d.size_bytes=</string></value></param>\
        <param><value><string>d.down.rate=</string></value></param>\
        </params></methodCall>
        """
        let url = try http.url(base: config.baseURL, path: "")
        let data = try await http.post(url, headers: authHeaders(), body: Data(xml.utf8))
        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("<fault>") { throw RtorrentError.actionFailed("XMLRPC fault in d.multicall2") }

        let values = Self.xmlrpcLeafValues(body)  // [hash, completed, size, rate, hash, …]
        var map: [String: DownloadProgress] = [:]
        for base in stride(from: 0, through: values.count - 4, by: 4) {
            let hash = values[base]
            guard !hash.isEmpty else { continue }
            let completed = Int64(values[base + 1]) ?? 0
            let size = Int64(values[base + 2]) ?? 0
            let rate = Int64(values[base + 3])
            let progress = size > 0 ? Double(completed) / Double(size) : 0
            map[hash.lowercased()] = DownloadProgress(progress: progress, downloadSpeed: rate)
        }
        return map
    }

    /// Leaf `<string>`/`<i8>`/`<i4>`/`<int>` contents of an XML-RPC response in
    /// document order — enough to read a `d.multicall2` result without a full
    /// XML parser (the multicall returns only the values we asked for).
    private static func xmlrpcLeafValues(_ xml: String) -> [String] {
        let pattern = "<(string|i8|i4|int)>([^<]*)</(?:string|i8|i4|int)>"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 2)) }
    }

    private func xmlrpcCall(method: String, stringParam: String) -> String {
        let escaped = stringParam
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>\
        <methodCall>\
        <methodName>\(method)</methodName>\
        <params><param><value><string>\(escaped)</string></value></param></params>\
        </methodCall>
        """
    }

    private func authHeaders() -> [String: String] {
        var headers = ["Content-Type": "text/xml"]
        if !config.username.isEmpty {
            let cred = "\(config.username):\(config.password)"
            headers["Authorization"] = "Basic \(Data(cred.utf8).base64EncodedString())"
        }
        return headers
    }
}
