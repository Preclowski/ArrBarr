import Testing
import ArrCore
import MCP
import Foundation
@testable import ArrMCPServer

@Test func endToEnd_listToolsOverHTTP() async throws {
    let controller = MCPServerController()
    // A minimally-"configured" Sonarr (fake host) so the catalog advertises its
    // tools. We only list tools here — nothing is actually called against it.
    let sonarr = ServiceConfig(enabled: true, baseURL: "http://127.0.0.1:9",
                               apiKey: "x", username: "", password: "")
    let inputs = MCPServerController.BackendInputs(
        sonarr: sonarr, radarr: .empty, lidarr: .empty, whisparr: .empty,
        aiKnowsAboutWhisparr: false, tmdbApiKey: "", downloadClients: .init())
    await controller.restart(with: .init(hostPort: "127.0.0.1:38419", requireAuth: false,
        token: "", disabledTools: [], backendInputs: inputs))
    defer { Task { await controller.stop() } }

    let client = Client(name: "test", version: "1")
    let transport = HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:38419/mcp")!)
    _ = try await client.connect(transport: transport)
    let (tools, _) = try await client.listTools()
    #expect(tools.contains { $0.name == "sonarr_get_series" })
    await client.disconnect()
    await controller.stop()
}
