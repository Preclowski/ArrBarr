import ArrCore
import MCP
import Logging

/// Wires a configured `LocalToolBackend` + tool catalog into an MCP `Server`.
/// One router can build many servers (one per HTTP session). The caller (the
/// HTTP host) owns `server.start(transport:)` — `makeServer()` only configures
/// and registers handlers, mirroring the SDK's own conformance host.
struct MCPCallRouter {
    let backend: LocalToolBackend
    let catalog: [MCPTool]
    let disabled: Set<String>
    let logger: Logger

    func makeServer() async -> Server {
        let server = Server(
            name: "ArrBarr",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        let catalog = self.catalog
        let disabled = self.disabled
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolCatalogBridge.sdkTools(catalog: catalog, disabled: disabled))
        }

        let backend = self.backend
        let logger = self.logger
        await server.withMethodHandler(CallTool.self) { [backend, disabled, logger] params in
            let name = params.name
            guard !disabled.contains(name) else {
                return CallTool.Result(
                    content: [.text(text: "Tool '\(name)' is disabled.", annotations: nil, _meta: nil)],
                    isError: true)
            }
            logger.info("tools/call", metadata: ["tool": .string(name)])

            // Destructive tools (indexer search / monitor → start downloads,
            // library mutations) require interactive, per-call confirmation via
            // MCP elicitation. We FAIL CLOSED: if the client can't confirm
            // (didn't advertise elicitation) or the user declines, the tool does
            // NOT run. An automated third-party client therefore gets read-only
            // access by default and can never trigger downloads/grabs unattended.
            if MCPToolWhitelist.isDestructive(name) {
                do {
                    let result = try await server.requestElicitation(
                        message: "Run \(name)? This may start downloads or change library state.",
                        requestedSchema: .init())
                    guard result.action == .accept else {
                        return CallTool.Result(
                            content: [.text(text: "Cancelled by user.", annotations: nil, _meta: nil)],
                            isError: false)
                    }
                } catch {
                    logger.notice("destructive tool blocked: client cannot confirm (no elicitation)",
                                  metadata: ["tool": .string(name)])
                    return CallTool.Result(
                        content: [.text(
                            text: "Tool '\(name)' changes server state and requires interactive confirmation, which this client does not support. It was not run.",
                            annotations: nil, _meta: nil)],
                        isError: true)
                }
            }

            do {
                let out = try await backend.callTool(
                    name: name,
                    arguments: JSONValueBridge.argumentsToJSON(params.arguments))
                return CallTool.Result(
                    content: [.text(text: out.text, annotations: nil, _meta: nil)],
                    isError: false)
            } catch {
                // Use the sanitized `localizedDescription` — interpolating the
                // raw error serializes a URLError's userInfo, which embeds the
                // internal arr base URL (host:port/path). Don't disclose topology.
                return CallTool.Result(
                    content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)],
                    isError: true)
            }
        }

        return server
    }
}
