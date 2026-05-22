import Foundation

@MainActor
public enum ChatViewModelFactory {
    public static func makePlaceholder() -> ChatViewModel {
        ChatViewModel(
            provider: UnavailableLLMProvider(),
            tools: [],
            invokeTool: { _, _ in ToolCallOutput(text: "") }
        )
    }

    public static func make(
        sonarr: ServiceConfig,
        radarr: ServiceConfig,
        lidarr: ServiceConfig = .empty,
        whisparr: ServiceConfig = .empty,
        aiKnowsAboutWhisparr: Bool = false,
        chatProvider: ChatProvider,
        openai: OpenAIConfig
    ) -> ChatViewModel {
        let backend: ToolBackend = LocalToolBackend(
            sonarr: sonarr, radarr: radarr, lidarr: lidarr,
            whisparr: whisparr, aiKnowsAboutWhisparr: aiKnowsAboutWhisparr
        )

        let llmTools = ChatToolCatalog.llmTools(includeWhisparr: aiKnowsAboutWhisparr)

        let invoke: @Sendable (String, JSONValue) async throws -> ToolCallOutput = { name, args in
            try await backend.callTool(name: name, arguments: args)
        }

        var vmRef: ChatViewModel? = nil
        let confirm: @Sendable (ToolCall) async -> JSONValue? = { [weak vmRef] call in
            guard let vm = vmRef else { return nil }
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
