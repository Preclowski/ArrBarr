import Testing
import Foundation
@testable import ArrCore

@Suite("MCPConfig")
struct MCPConfigTests {
    @Test("empty config is not configured")
    func emptyNotConfigured() {
        #expect(MCPConfig.empty.isConfigured == false)
    }

    @Test("disabled config is not configured even with valid URL")
    func disabledNotConfigured() {
        let cfg = MCPConfig(enabled: false, baseURL: "http://nas.local:3000/mcp", bearerToken: "")
        #expect(cfg.isConfigured == false)
    }

    @Test("enabled with valid http URL is configured")
    func httpConfigured() {
        let cfg = MCPConfig(enabled: true, baseURL: "http://nas.local:3000/mcp", bearerToken: "")
        #expect(cfg.isConfigured == true)
    }

    @Test("enabled with valid https URL is configured")
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
