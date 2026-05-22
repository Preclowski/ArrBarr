import Testing
import Foundation
@testable import ArrCore

@Suite("MCPClient", .serialized)
struct MCPClientTests {
    /// URL-protocol stub: intercepts requests and returns method-keyed responses.
    /// Tests set `responses[method]` for the methods they care about; everything
    /// else gets a sensible default (initialize → ok, notifications/initialized → 202).
    final class StubProtocol: URLProtocol {
        struct Response { let status: Int; let body: Data; let contentType: String; let headers: [String: String] }

        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?
        nonisolated(unsafe) static var requests: [(method: String, body: Data, sessionHeader: String?)] = []
        nonisolated(unsafe) static var responses: [String: Response] = [:]

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            Self.lastRequest = request
            let body: Data
            if let stream = request.httpBodyStream {
                body = Self.consume(stream)
            } else {
                body = request.httpBody ?? Data()
            }
            Self.lastBody = body

            let method = Self.extractMethod(from: body)
            Self.requests.append((method, body, request.value(forHTTPHeaderField: "Mcp-Session-Id")))

            let r = Self.responses[method] ?? Self.defaultResponse(for: method)
            var headerFields = ["Content-Type": r.contentType]
            for (k, v) in r.headers { headerFields[k] = v }
            let url = request.url ?? URL(string: "about:blank")!
            let resp = HTTPURLResponse(url: url, statusCode: r.status,
                                      httpVersion: "HTTP/1.1",
                                      headerFields: headerFields)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: r.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func consume(_ stream: InputStream) -> Data {
            stream.open(); defer { stream.close() }
            var out = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: 4096); if n <= 0 { break }
                out.append(buf, count: n)
            }
            return out
        }

        static func extractMethod(from data: Data) -> String {
            guard !data.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let m = obj["method"] as? String else { return "" }
            return m
        }

        static func defaultResponse(for method: String) -> Response {
            switch method {
            case "initialize":
                let body = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"stub","version":"0"}}}"#
                return Response(status: 200, body: body.data(using: .utf8)!, contentType: "application/json", headers: [:])
            case "notifications/initialized":
                return Response(status: 202, body: Data(), contentType: "application/json", headers: [:])
            case "tools/list":
                return Response(status: 200, body: #"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.data(using: .utf8)!,
                               contentType: "application/json", headers: [:])
            case "tools/call":
                return Response(status: 200, body: #"{"jsonrpc":"2.0","id":1,"result":{"content":[],"isError":false}}"#.data(using: .utf8)!,
                               contentType: "application/json", headers: [:])
            default:
                return Response(status: 200, body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#.data(using: .utf8)!,
                               contentType: "application/json", headers: [:])
            }
        }

        static func reset() {
            lastRequest = nil
            lastBody = nil
            requests = []
            responses = [:]
        }
    }

    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func client(token: String = "") -> MCPClient {
        MCPClient(
            config: MCPConfig(enabled: true, baseURL: "http://x/mcp", bearerToken: token),
            session: session()
        )
    }

    @Test("listTools triggers initialize handshake first, then sends tools/list")
    func listToolsRunsHandshake() async throws {
        StubProtocol.reset()
        StubProtocol.responses["tools/list"] = .init(
            status: 200,
            body: #"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"sonarr_search","description":"d","inputSchema":{"type":"object"}}]}}"#.data(using: .utf8)!,
            contentType: "application/json",
            headers: [:]
        )
        let tools = try await client().listTools()
        #expect(tools.count == 1)
        #expect(tools[0].name == "sonarr_search")
        // Three requests: initialize, notifications/initialized, tools/list
        let methods = StubProtocol.requests.map(\.method)
        #expect(methods == ["initialize", "notifications/initialized", "tools/list"])
    }

    @Test("session id from initialize is echoed on subsequent requests")
    func sessionIDEchoed() async throws {
        StubProtocol.reset()
        StubProtocol.responses["initialize"] = .init(
            status: 200,
            body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.data(using: .utf8)!,
            contentType: "application/json",
            headers: ["Mcp-Session-Id": "abc-xyz-123"]
        )
        StubProtocol.responses["tools/list"] = .init(
            status: 200,
            body: #"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.data(using: .utf8)!,
            contentType: "application/json",
            headers: [:]
        )
        _ = try await client().listTools()
        // First request (initialize) didn't have a session id yet; later two should.
        #expect(StubProtocol.requests[0].sessionHeader == nil)
        #expect(StubProtocol.requests[1].sessionHeader == "abc-xyz-123")
        #expect(StubProtocol.requests[2].sessionHeader == "abc-xyz-123")
    }

    @Test("handshake done only once across multiple calls")
    func handshakeOnce() async throws {
        StubProtocol.reset()
        _ = try await client().listTools()
        let firstRoundMethods = StubProtocol.requests.map(\.method)
        #expect(firstRoundMethods == ["initialize", "notifications/initialized", "tools/list"])
        // Re-using the same client (same MCPClient instance) — fresh listTools
        // should NOT re-handshake.
        let c = MCPClient(
            config: MCPConfig(enabled: true, baseURL: "http://x/mcp", bearerToken: ""),
            session: session()
        )
        StubProtocol.requests = []
        _ = try await c.listTools()
        _ = try await c.listTools()
        let methods = StubProtocol.requests.map(\.method)
        // First listTools triggers handshake; second reuses it.
        #expect(methods == ["initialize", "notifications/initialized", "tools/list", "tools/list"])
    }

    @Test("listTools returns parsed tools")
    func listTools() async throws {
        StubProtocol.reset()
        StubProtocol.responses["tools/list"] = .init(
            status: 200,
            body: #"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"sonarr_search","description":"d","inputSchema":{"type":"object"}}]}}"#.data(using: .utf8)!,
            contentType: "application/json",
            headers: [:]
        )
        let tools = try await client().listTools()
        #expect(tools.count == 1)
        #expect(tools[0].name == "sonarr_search")
    }

    @Test("bearer token forwarded as Authorization header")
    func bearer() async throws {
        StubProtocol.reset()
        _ = try await client(token: "secret").listTools()
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test("no Authorization header when token empty")
    func noBearer() async throws {
        StubProtocol.reset()
        _ = try await client(token: "").listTools()
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("callTool wraps arguments and returns text content")
    func callTool() async throws {
        StubProtocol.reset()
        StubProtocol.responses["tools/call"] = .init(
            status: 200,
            body: #"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"OK"}],"isError":false}}"#.data(using: .utf8)!,
            contentType: "application/json",
            headers: [:]
        )
        let result = try await client().callTool(name: "sonarr_search", arguments: .object(["query": .string("Severance")]))
        #expect(result.content.first?.text == "OK")
        #expect(result.isError == false)
    }

    @Test("JSON-RPC error surfaces as thrown MCPError")
    func rpcError() async throws {
        StubProtocol.reset()
        StubProtocol.responses["tools/list"] = .init(
            status: 200,
            body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"not found"}}"#.data(using: .utf8)!,
            contentType: "application/json",
            headers: [:]
        )
        await #expect(throws: MCPError.self) {
            _ = try await self.client().listTools()
        }
    }

    @Test("non-2xx HTTP status throws MCPError.http")
    func httpError() async throws {
        StubProtocol.reset()
        StubProtocol.responses["tools/list"] = .init(
            status: 503, body: Data(), contentType: "application/json", headers: [:]
        )
        do {
            _ = try await client().listTools()
            Issue.record("expected throw")
        } catch let MCPError.http(status) {
            #expect(status == 503)
        } catch {
            Issue.record("expected MCPError.http, got \(error)")
        }
    }

    @Test("SSE response body is parsed (first data frame)")
    func sseFrame() async throws {
        StubProtocol.reset()
        StubProtocol.responses["tools/list"] = .init(
            status: 200,
            body: """
            event: message
            data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}

            """.data(using: .utf8)!,
            contentType: "text/event-stream",
            headers: [:]
        )
        let tools = try await client().listTools()
        #expect(tools.isEmpty)
    }
}
