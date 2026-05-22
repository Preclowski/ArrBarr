import Testing
import Foundation
@testable import ArrCore

@Suite("MCPConfig")
struct MCPConfigTests {
    @Test("empty config is not configured")
    func emptyNotConfigured() {
        #expect(MCPConfig.empty.isConfigured == false)
    }

    @Test("valid http URL is configured regardless of enabled flag")
    func httpConfigured() {
        let cfg = MCPConfig(enabled: false, baseURL: "http://nas.local:3000/mcp", bearerToken: "")
        #expect(cfg.isConfigured == true)
    }

    @Test("valid https URL is configured")
    func httpsConfigured() {
        let cfg = MCPConfig(enabled: true, baseURL: "https://mcp.example.com/mcp", bearerToken: "abc")
        #expect(cfg.isConfigured == true)
    }

    @Test("non-http scheme rejected")
    func ftpRejected() {
        let cfg = MCPConfig(enabled: true, baseURL: "ftp://nas.local/mcp", bearerToken: "")
        #expect(cfg.isConfigured == false)
    }

    @Test("empty URL string rejected")
    func emptyURLRejected() {
        let cfg = MCPConfig(enabled: true, baseURL: "", bearerToken: "")
        #expect(cfg.isConfigured == false)
    }

    @Test("codable round-trip preserves all fields")
    func codable() throws {
        let cfg = MCPConfig(enabled: true, baseURL: "https://x/mcp", bearerToken: "tok")
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(MCPConfig.self, from: data)
        #expect(back == cfg)
    }
}
