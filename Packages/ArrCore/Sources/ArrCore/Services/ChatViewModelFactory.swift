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

    public static func make(
        toolSource: ToolSource,
        mcp: MCPConfig,
        sonarr: ServiceConfig,
        radarr: ServiceConfig,
        chatProvider: ChatProvider,
        openai: OpenAIConfig
    ) -> ChatViewModel {
        let backend: ToolBackend
        switch toolSource {
        case .builtIn:
            backend = LocalToolBackend(sonarr: sonarr, radarr: radarr)
        case .externalMCP:
            guard mcp.isConfigured else { return makePlaceholder() }
            backend = MCPClient(config: mcp)
        }

        let llmTools = ChatToolCatalog.llmTools

        let invoke: @Sendable (String, JSONValue) async throws -> String = { name, args in
            try await backend.callTool(name: name, arguments: args)
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
            tools: llmTools,
            invokeTool: invoke
        )
        vmRef = vm
        return vm
    }
}
