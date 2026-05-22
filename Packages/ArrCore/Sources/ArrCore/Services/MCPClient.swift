import Foundation

public enum MCPError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL
    case http(status: Int)
    case rpc(code: Int, message: String)
    case decoding(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "MCP server URL is invalid."
        case .http(let status): return "MCP server returned HTTP \(status)."
        case .rpc(let code, let message): return "MCP error \(code): \(message)"
        case .decoding(let msg): return "Couldn't decode MCP response: \(msg)"
        case .empty: return "MCP server returned an empty response."
        }
    }
}

public actor MCPClient {
    /// Protocol version we advertise to the server during `initialize`.
    /// mcp-arr ≥ 0.x speaks 2025-06-18.
    public static let protocolVersion = "2025-06-18"

    private let config: MCPConfig
    private let session: URLSession
    private var nextID: Int = 1

    /// Captured from the `Mcp-Session-Id` header on the initialize response.
    /// Subsequent requests echo it back so the server can route to the same session.
    private var sessionID: String?
    private var didInitialize: Bool = false

    public init(config: MCPConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func listTools() async throws -> [MCPTool] {
        try await ensureInitialized()
        let result: ToolsListResult = try await rpc(method: "tools/list", params: .object([:]))
        return result.tools
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> String {
        try await ensureInitialized()
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments,
        ])
        let result: ToolsCallResult = try await rpc(method: "tools/call", params: params)
        return result.content.compactMap(\.text).joined(separator: "\n")
    }

    /// MCP requires `initialize` (request) + `notifications/initialized` (notification)
    /// before any other method. We do both lazily on the first call.
    private func ensureInitialized() async throws {
        guard !didInitialize else { return }
        let params: JSONValue = .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("ArrBarr"),
                "version": .string("0.1.0"),
            ]),
        ])
        let _: InitializeResult = try await rpc(method: "initialize", params: params)
        try await notify(method: "notifications/initialized", params: .object([:]))
        didInitialize = true
    }

    private func nextRequestID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func makeRequest() throws -> URLRequest {
        guard let url = URL(string: config.baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw MCPError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if !config.bearerToken.isEmpty {
            req.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let sid = sessionID {
            req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        return req
    }

    private func rpc<R: Decodable & Sendable>(method: String, params: JSONValue) async throws -> R {
        var req = try makeRequest()
        let body = JSONRPCRequest(id: nextRequestID(), method: method, params: params)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        req.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MCPError.empty }
        guard (200..<300).contains(http.statusCode) else { throw MCPError.http(status: http.statusCode) }

        // Server may issue a session id on the initialize response. Capture
        // and echo on subsequent requests.
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
            sessionID = sid
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let envelopeData: Data
        if contentType.contains("text/event-stream") {
            guard let frame = Self.firstSSEData(in: data) else {
                throw MCPError.decoding("SSE body contained no data: frame")
            }
            envelopeData = frame
        } else {
            envelopeData = data
        }

        let envelope: JSONRPCResponse<R>
        do {
            envelope = try JSONDecoder().decode(JSONRPCResponse<R>.self, from: envelopeData)
        } catch {
            throw MCPError.decoding(String(describing: error))
        }
        if let err = envelope.error { throw MCPError.rpc(code: err.code, message: err.message) }
        guard let result = envelope.result else { throw MCPError.empty }
        return result
    }

    /// Send a JSON-RPC notification (no id, no response payload expected).
    /// Server is required to return 202 Accepted with empty body.
    private func notify(method: String, params: JSONValue) async throws {
        var req = try makeRequest()
        let body = JSONRPCNotification(method: method, params: params)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        req.httpBody = try encoder.encode(body)

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MCPError.empty }
        guard (200..<300).contains(http.statusCode) else { throw MCPError.http(status: http.statusCode) }
    }

    /// Extract the first `data:` payload from an SSE body. Handles single-line
    /// `data:` frames (which is what mcp-arr emits for single-shot responses).
    static func firstSSEData(in data: Data) -> Data? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data:") {
                let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                return payload.data(using: .utf8)
            }
        }
        return nil
    }
}
