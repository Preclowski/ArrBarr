import Foundation

public enum MCPError: Error, Equatable, Sendable {
    case invalidURL
    case http(status: Int)
    case rpc(code: Int, message: String)
    case decoding(String)
    case empty
}

public actor MCPClient {
    private let config: MCPConfig
    private let session: URLSession
    private var nextID: Int = 1

    public init(config: MCPConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func listTools() async throws -> [MCPTool] {
        let result: ToolsListResult = try await rpc(method: "tools/list", params: .object([:]))
        return result.tools
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolsCallResult {
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments,
        ])
        let result: ToolsCallResult = try await rpc(method: "tools/call", params: params)
        return result
    }

    private func nextRequestID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func rpc<R: Decodable & Sendable>(method: String, params: JSONValue) async throws -> R {
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
        let body = JSONRPCRequest(id: nextRequestID(), method: method, params: params)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        req.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MCPError.empty }
        guard (200..<300).contains(http.statusCode) else { throw MCPError.http(status: http.statusCode) }

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
