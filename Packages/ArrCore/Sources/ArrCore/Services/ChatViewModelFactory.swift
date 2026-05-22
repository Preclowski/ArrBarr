import Foundation

@MainActor
public enum ChatViewModelFactory {
    public static func makePlaceholder() -> ChatViewModel {
        ChatViewModel(
            provider: UnavailableLLMProvider(),
            tools: [],
            invokeTool: { _, _ in "" }
        )
    }

    /// Build a fully-wired chat view-model. Caller is responsible for
    /// re-creating it (via `.id(...)`) when MCP config changes.
    public static func make(config: MCPConfig) -> ChatViewModel {
        guard config.isConfigured else { return makePlaceholder() }
        let client = MCPClient(config: config)
        let mcpTools = MCPToolWhitelist.v1Allowed.sorted().map { name in
            LLMTool(name: name, description: "MCP tool: \(name)", inputSchema: .object([:]))
        }

        let provider: LLMProvider
        if #available(macOS 26.0, iOS 26.0, *) {
            provider = FoundationModelsProvider()
        } else {
            provider = UnavailableLLMProvider()
        }

        return ChatViewModel(
            provider: provider,
            tools: mcpTools,
            invokeTool: { name, args in
                let result = try await client.callTool(name: name, arguments: args)
                return result.content.compactMap(\.text).joined(separator: "\n")
            }
        )
    }
}
