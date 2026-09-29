import ArrCore
import Foundation
import MCP
import Logging
import MediaKit

/// One router builds a server per HTTP session; the HTTP host owns `server.start(transport:)`.
struct MCPCallRouter {
    let backend: LocalToolBackend
    let catalog: [ToolDefinition]
    let disabled: Set<String>
    let logger: Logger

    func makeServer() async -> Server {
        let server = Server(
            name: "ArrBarr",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        let catalog = self.catalog
        let disabled = self.disabled
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolCatalogBridge.sdkTools(catalog: catalog, disabled: disabled))
        }

        let backend = self.backend
        let logger = self.logger
        // Weak: the handler is stored on `server`, so a strong capture would keep every closed session alive.
        await server.withMethodHandler(CallTool.self) { [backend, disabled, logger, weak server] params in
            let name = params.name
            guard !disabled.contains(name) else {
                return CallTool.Result(
                    content: [.text(text: "Tool '\(name)' is disabled.", annotations: nil, _meta: nil)],
                    isError: true)
            }
            // Arrival only: `LocalToolBackend.callTool` logs every call's outcome.
            logger.debug("tools/call", metadata: ["tool": .string(name)])

            // Fails closed: without elicitation support or with a decline, a destructive tool
            // does not run, so an unattended client can never trigger downloads.
            let session = server
            let confirm: ToolConfirmationHandler = { call in
                guard let server = session else { return .unavailable }
                do {
                    let result = try await server.requestElicitation(
                        message: "Run \(call.name)? This may start downloads or change library state.",
                        requestedSchema: .init())
                    return result.action == .accept ? .approved(call.arguments) : .declined
                } catch {
                    return .unavailable
                }
            }

            do {
                let out = try await ToolConfirmationContext.$handler.withValue(confirm) {
                    try await backend.callTool(
                        name: name,
                        arguments: JSONValueBridge.argumentsToJSON(params.arguments))
                }
                return CallTool.Result(
                    content: [.text(text: out.text, annotations: nil, _meta: nil)],
                    isError: false)
            } catch LocalToolError.confirmationDeclined(_) {
                return CallTool.Result(
                    content: [.text(text: "Cancelled by user.", annotations: nil, _meta: nil)],
                    isError: false)
            } catch LocalToolError.confirmationUnavailable(_) {
                logger.notice("destructive tool blocked: client cannot confirm (no elicitation)",
                              metadata: ["tool": .string(name)])
                return CallTool.Result(
                    content: [.text(
                        text: "Tool '\(name)' changes server state and requires interactive confirmation, which this client does not support. It was not run.",
                        annotations: nil, _meta: nil)],
                    isError: true)
            } catch {
                // Not the raw error: a URLError's userInfo embeds the internal arr base URL.
                return CallTool.Result(
                    content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)],
                    isError: true)
            }
        }

        return server
    }
}
