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

@Test func refusesNonLoopbackBindWithoutAuth() async throws {
    let controller = MCPServerController()
    actor StatusBox {
        var statuses: [MCPServerController.Status] = []
        func append(_ s: MCPServerController.Status) { statuses.append(s) }
    }
    let box = StatusBox()
    await controller.setStatusHandler { s in Task { await box.append(s) } }
    let inputs = MCPServerController.BackendInputs(
        sonarr: .empty, radarr: .empty, lidarr: .empty, whisparr: .empty,
        aiKnowsAboutWhisparr: false, tmdbApiKey: "", downloadClients: .init())
    await controller.restart(with: .init(hostPort: "0.0.0.0:38420", requireAuth: false,
        token: "", disabledTools: [], backendInputs: inputs))
    // Give the detached status Tasks a beat to land in the box.
    try await Task.sleep(nanoseconds: 200_000_000)
    let statuses = await box.statuses
    let failed = statuses.contains { if case .failed = $0 { true } else { false } }
    let running = statuses.contains { if case .running = $0 { true } else { false } }
    #expect(failed && !running)
    await controller.stop()
}
