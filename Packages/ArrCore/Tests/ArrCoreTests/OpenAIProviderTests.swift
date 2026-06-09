import Testing
import Foundation
@testable import ArrCore

@Suite("OpenAIProvider", .serialized)
struct OpenAIProviderTests {
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?
        nonisolated(unsafe) static var nextResponseBody: Data = Data()
        nonisolated(unsafe) static var nextStatus: Int = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.lastRequest = request
            if let stream = request.httpBodyStream {
                Self.lastBody = Self.consume(stream)
            } else {
                Self.lastBody = request.httpBody
            }
            let url = request.url ?? URL(string: "about:blank")!
            let resp = HTTPURLResponse(url: url, statusCode: Self.nextStatus, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.nextResponseBody)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        static func consume(_ s: InputStream) -> Data {
            s.open(); defer { s.close() }
            var out = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: 4096); if n <= 0 { break }
                out.append(buf, count: n)
            }
            return out
        }
        static func reset() {
            lastRequest = nil; lastBody = nil
            nextResponseBody = Data(); nextStatus = 200
        }
    }
    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }
    private func provider() -> OpenAIProvider {
        OpenAIProvider(
            config: OpenAIConfig(baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-or-test", model: "openai/gpt-4o-mini"),
            session: session()
        )
    }

    @Test("text response, no tool calls")
    func textResponse() async throws {
        StubProtocol.reset()
        StubProtocol.nextResponseBody = """
        {"choices":[{"message":{"role":"assistant","content":"Hi there"}}]}
        """.data(using: .utf8)!
        let resp = try await provider().respond(prompt: "hi", tools: [], history: [])
        #expect(resp.text == "Hi there")
        #expect(resp.toolCalls.isEmpty)
        #expect(resp.toolResults == nil)
        // Authorization header sent
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
    }

    @Test("tool call surfaces as ToolCall with id and parsed args")
    func toolCall() async throws {
        StubProtocol.reset()
        StubProtocol.nextResponseBody = """
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
            {"id":"call_abc","type":"function","function":{"name":"sonarr_search","arguments":"{\\"query\\":\\"Severance\\"}"}}
        ]}}]}
        """.data(using: .utf8)!
        let resp = try await provider().respond(
            prompt: "find Severance",
            tools: [LLMTool(name: "sonarr_search", description: "search sonarr", inputSchema: .object([:]))],
            history: []
        )
        #expect(resp.toolCalls.count == 1)
        #expect(resp.toolCalls[0].id == "call_abc")
        #expect(resp.toolCalls[0].name == "sonarr_search")
        if case .object(let dict) = resp.toolCalls[0].arguments,
           case .string(let q) = dict["query"] {
            #expect(q == "Severance")
        } else {
            Issue.record("arguments did not decode to object with query string")
        }
    }

    @Test("non-2xx throws OpenAIError.http with body")
    func httpError() async throws {
        StubProtocol.reset()
        StubProtocol.nextStatus = 401
        StubProtocol.nextResponseBody = #"{"error":{"message":"bad key"}}"#.data(using: .utf8)!
        do {
            _ = try await provider().respond(prompt: "x", tools: [], history: [])
            Issue.record("expected throw")
        } catch let OpenAIError.http(status, body) {
            #expect(status == 401)
            #expect(body.contains("bad key"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("request body has model, system+user messages, and tool when present")
    func requestShape() async throws {
        StubProtocol.reset()
        StubProtocol.nextResponseBody = #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.data(using: .utf8)!
        _ = try await provider().respond(
            prompt: "hi",
            tools: [LLMTool(name: "sonarr_search", description: "search", inputSchema: .object([:]))],
            history: []
        )
        let body = String(data: StubProtocol.lastBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"model\":\"openai/gpt-4o-mini\""))
        #expect(body.contains("\"role\":\"system\""))
        #expect(body.contains("\"role\":\"user\""))
        #expect(body.contains("sonarr_search"))
        #expect(body.contains("\"tool_choice\":\"auto\""))
    }

    // MARK: - Dynamic arr clause + reply language

    @Test("system prompt names only the arrs whose tools are present")
    func systemPromptArrsAreDynamic() {
        let tools = [
            LLMTool(name: "radarr_search", description: "", inputSchema: .object([:])),
            LLMTool(name: "lidarr_search", description: "", inputSchema: .object([:])),
        ]
        let body = OpenAIProvider.buildRequestBody(model: "m", prompt: "hi", tools: tools, history: [], replyLanguage: "Polish")
        let system = body.messages.first { $0.role == "system" }?.content ?? ""
        #expect(system.contains("Radarr (movies) and Lidarr (music)"))
        #expect(!system.contains("Sonarr"))
        // The user's language wins; the app language is only the fallback.
        #expect(system.contains("same language as the user"))
        #expect(system.contains("default to Polish"))
    }

    @Test("SystemPromptComposer.arrsClause joins present arrs, falls back when none")
    func arrsClause() {
        let all = [
            LLMTool(name: "sonarr_search", description: "", inputSchema: .object([:])),
            LLMTool(name: "radarr_search", description: "", inputSchema: .object([:])),
            LLMTool(name: "whisparr_search", description: "", inputSchema: .object([:])),
        ]
        #expect(SystemPromptComposer.arrsClause(tools: all) == "Sonarr (TV), Radarr (movies) and Whisparr (adult content)")
        #expect(SystemPromptComposer.arrsClause(tools: []) == "your self-hosted *arr media stack")
    }

    @Test("replyLanguageName maps codes to English names")
    func replyLanguageName() {
        #expect(ChatViewModelFactory.replyLanguageName(appLanguage: "pl") == "Polish")
        #expect(ChatViewModelFactory.replyLanguageName(appLanguage: "de") == "German")
    }
}
