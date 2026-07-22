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
            throw RtorrentError.actionFailed(Self.faultMessage(body, method: methodName))
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
            throw RtorrentError.actionFailed(Self.faultMessage(body, method: "system.client_version"))
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
    /// The chunking is verified before it's trusted — see the guards below.
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
        if body.contains("<fault>") {
            throw RtorrentError.actionFailed(Self.faultMessage(body, method: "d.multicall2"))
        }

        let values = Self.xmlrpcLeafValues(body)  // [hash, completed, size, rate, hash, …]
        // Chunking by four only holds while every requested value comes back in
        // a type the scraper matches. Let one of them arrive as `<double>` or
        // `<boolean>` and it drops out of the window, after which each torrent
        // silently inherits the next one's numbers — plausible, wrong, and
        // reported as if it were fine. Refuse the whole batch instead of
        // showing invented progress: a count that isn't a multiple of four, or
        // a chunk not starting with an info-hash, means alignment is gone.
        guard values.count.isMultiple(of: 4) else { return [:] }
        var map: [String: DownloadProgress] = [:]
        for base in stride(from: 0, to: values.count, by: 4) {
            let hash = values[base]
            guard Self.isInfoHash(hash) else { return [:] }
            let completed = Int64(values[base + 1]) ?? 0
            let size = Int64(values[base + 2]) ?? 0
            let rate = Int64(values[base + 3])
            let progress = size > 0 ? Double(completed) / Double(size) : 0
            map[hash.lowercased()] = DownloadProgress(progress: progress, downloadSpeed: rate)
        }
        return map
    }

    /// A BitTorrent info-hash as `d.hash` returns it: exactly 40 hex digits.
    /// Used purely as an alignment check on the chunked multicall values.
    private static func isInfoHash(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(\.isHexDigit)
    }

    /// The user-facing reason for an XML-RPC `<fault>`: the server's own
    /// `faultString` when it sent one, else a fallback naming the call.
    private static func faultMessage(_ xml: String, method: String) -> String {
        xmlrpcFaultString(xml) ?? String(
            format: String(localized: "XML-RPC fault in response to %@", bundle: .module),
            method
        )
    }

    /// Extract `faultString` from an XML-RPC fault struct. That member carries
    /// the actual cause — "Could not find info-hash", "Method 'd.stop' is not
    /// defined" — so dropping it leaves every different failure reading exactly
    /// the same. The member's value may be typed
    /// (`<value><string>…</string></value>`) or bare (`<value>…</value>`, which
    /// XML-RPC defines as a string), so both shapes are accepted.
    private static func xmlrpcFaultString(_ xml: String) -> String? {
        guard let name = xml.range(of: "<name>faultString</name>"),
              let open = xml.range(of: "<value>", range: name.upperBound..<xml.endIndex),
              let close = xml.range(of: "</value>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        var inner = String(xml[open.upperBound..<close.lowerBound])
        if let start = inner.range(of: "<string>"),
           let end = inner.range(of: "</string>", range: start.upperBound..<inner.endIndex) {
            inner = String(inner[start.upperBound..<end.lowerBound])
        }
        let text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            // "&amp;" last, so an already-escaped entity ("&amp;lt;") that
            // decodes to "&lt;" isn't then decoded a second time into "<".
            .replacingOccurrences(of: "&amp;", with: "&")
        return text.isEmpty ? nil : text
    }

    /// Leaf `<string>`/`<i8>`/`<i4>`/`<int>` contents of an XML-RPC response in
    /// document order — enough to read a `d.multicall2` result without a full
    /// XML parser (the multicall returns only the values we asked for). It
    /// matches nothing else, so callers must verify the values line up before
    /// trusting their positions; see `fetchProgress`.
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
