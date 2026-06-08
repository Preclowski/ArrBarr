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

            // Server-side confirmation for destructive tools, where the client
            // supports elicitation. `requestElicitation` throws when the client
            // didn't advertise the capability — in that case we proceed (the
            // tool's `destructiveHint` annotation already warned the client).
            if MCPToolWhitelist.isDestructive(name) {
                do {
                    let result = try await server.requestElicitation(
                        message: "Run \(name)? This may start downloads or change library state.",
                        requestedSchema: .init())
                    if result.action != .accept {
                        return CallTool.Result(
                            content: [.text(text: "Cancelled by user.", annotations: nil, _meta: nil)],
                            isError: false)
                    }
                } catch {
                    logger.debug("elicitation unsupported; proceeding",
                                 metadata: ["tool": .string(name)])
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
                return CallTool.Result(
                    content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                    isError: true)
            }
        }

        return server
    }
}
