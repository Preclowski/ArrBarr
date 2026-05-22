import Testing
import Foundation
@testable import ArrCore

@Suite("MCPClient", .serialized)
struct MCPClientTests {
    /// URL-protocol stub that intercepts ALL requests so we don't hit the network.
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?
        nonisolated(unsafe) static var nextResponseBody: Data = Data()
        nonisolated(unsafe) static var nextStatus: Int = 200
        nonisolated(unsafe) static var nextContentType: String = "application/json"

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.lastRequest = request
            // URLSession may deliver the body via httpBodyStream rather than httpBody for some configs.
            if let stream = request.httpBodyStream {
                Self.lastBody = Self.consume(stream)
            } else {
                Self.lastBody = request.httpBody
            }
            let url = request.url ?? URL(string: "about:blank")!
            let resp = HTTPURLResponse(url: url, statusCode: Self.nextStatus,
                                      httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": Self.nextContentType])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.nextResponseBody)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func consume(_ stream: InputStream) -> Data {
            stream.open(); defer { stream.close() }
            var out = Data()
            let bufSize = 4096
            var buf = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: bufSize)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            return out
        }

        static func reset() {
            lastRequest = nil
            lastBody = nil
            nextResponseBody = Data()
            nextStatus = 200
            nextContentType = "application/json"
        }
    }

    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test("listTools issues POST with correct method and parses tools")
    func listTools() async throws {
        StubProtocol.reset()
        StubProtocol.nextResponseBody = """
        {"jsonrpc":"2.0","id":1,"result":{"tools":[
            {"name":"sonarr_search","description":"d","inputSchema":{"type":"object"}}
        ]}}
        """.data(using: .utf8)!
        let client = MCPClient(
            config: MCPConfig(enabled: true, baseURL: "http://x/mcp", bearerToken: ""),
            session: session()
        )
        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools[0].name == "sonarr_search")
        #expect(StubProtocol.lastRequest?.httpMethod == "POST")
        let body = String(data: StubProtocol.lastBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("tools/list"))
    }

    @Test("bearer token forwarded as Authorization header")
    func bearer() async throws {
        StubProtocol.reset()
        StubProtocol.nextResponseBody = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.data(using: .utf8)!
        let client = MCPClient(
            config: MCPConfig(enabled: true, baseURL: "http://x/mcp", bearerToken: "secret"),
            session: session()
        )
        _ = try await client.listTools()
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test("no Authorization header when token empty")
    func noBearer() async throws {
        StubProtocol.reset()
        StubProtocol.nextResponseBody = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.data(using: .utf8)!
        let client = MCPClient(
            config: MCPConfig(enabled: true, baseURL: "http://x/mcp", bearerToken: ""),
            session: session()
        )
        _ = try await client.listTools()
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("callTool wraps arguments and returns text content")
    func callTool() async throws {
        StubProtocol.reset()
        StubProtocol.nextResponseBody = """
        {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"OK"}],"isError":false}}
        """.data(using: .utf8)!
        let client = MCPClient(
            config: MCPConfig(enabled: true, baseURL: "http://x/mcp", bearerToken: ""),
            session: session()
        )
        let result = try await client.callTool(name: "sonarr_search", arguments: .object(["query": .string("Severance")]))
        #expect(result.content.first?.text == "OK")
        #expect(result.isError == false)
    }

    @Test("JSON-RPC error surfaces as thrown MCPError")
    func rpcError() async throws {
        StubProtocol.reset()
        StubProtocol.nextResponseBody = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"not found"}}"#.data(using: .utf8)!
        let client = MCPClient(
            config: MCPConfig(enabled: true, baseURL: "http://x/mcp", bearerToken: ""),
            session: session()
        )
        await #expect(throws: MCPError.self) {
            _ = try await client.listTools()
        }
    }

    @Test("non-2xx HTTP status throws MCPError.http")
    func httpError() async throws {
        StubProtocol.reset()
        StubProtocol.nextStatus = 503
        StubProtocol.nextResponseBody = Data()
        let client = MCPClient(
            config: MCPConfig(enabled: true, baseURL: "http://x/mcp", bearerToken: ""),
            session: session()
        )
        do {
            _ = try await client.listTools()
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
        StubProtocol.nextContentType = "text/event-stream"
        StubProtocol.nextResponseBody = """
        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}

        """.data(using: .utf8)!
        let client = MCPClient(
            config: MCPConfig(enabled: true, baseURL: "http://x/mcp", bearerToken: ""),
            session: session()
        )
        let tools = try await client.listTools()
        #expect(tools.isEmpty)
    }
}
