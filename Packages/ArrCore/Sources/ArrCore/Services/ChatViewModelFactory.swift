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

    public static func make(mcp: MCPConfig, chatProvider: ChatProvider, openai: OpenAIConfig) -> ChatViewModel {
        guard mcp.isConfigured else { return makePlaceholder() }
        let client = MCPClient(config: mcp)
        let mcpTools = MCPToolWhitelist.v1Allowed.sorted().map { name in
            LLMTool(name: name, description: "MCP tool: \(name)", inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]))
        }

        let invoke: @Sendable (String, JSONValue) async throws -> String = { name, args in
            let result = try await client.callTool(name: name, arguments: args)
            return result.content.compactMap(\.text).joined(separator: "\n")
        }

        var vmRef: ChatViewModel? = nil
        let confirm: @Sendable (ToolCall) async -> Bool = { [weak vmRef] call in
            guard let vm = vmRef else { return false }
            return await vm.awaitConfirm(call)
        }

        let provider: LLMProvider
        switch chatProvider {
        case .foundationModels:
            if #available(macOS 26.0, iOS 26.0, *) {
                provider = FoundationModelsProvider(invokeTool: invoke, confirmDestructive: confirm)
            } else {
                provider = UnavailableLLMProvider()
            }
        case .openai:
            if openai.isConfigured {
                provider = OpenAIProvider(config: openai)
            } else {
                provider = UnavailableLLMProvider()
            }
        }

        let vm = ChatViewModel(
            provider: provider,
            tools: mcpTools,
            invokeTool: invoke
        )
        vmRef = vm
        return vm
    }
}
