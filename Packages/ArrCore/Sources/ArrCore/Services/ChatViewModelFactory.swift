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
        tmdbApiKey: String = "",
        chatProvider: ChatProvider,
        openai: OpenAIConfig
    ) -> ChatViewModel {
        let backend: ToolBackend = LocalToolBackend(
            sonarr: sonarr, radarr: radarr, lidarr: lidarr,
            whisparr: whisparr, aiKnowsAboutWhisparr: aiKnowsAboutWhisparr,
            tmdbApiKey: tmdbApiKey
        )

        let tmdbEnabled = !tmdbApiKey.isEmpty
        let llmTools = ChatToolCatalog.llmTools(
            includeSonarr: sonarr.isConfigured,
            includeRadarr: radarr.isConfigured,
            includeLidarr: lidarr.isConfigured,
            includeWhisparr: whisparr.isConfigured && aiKnowsAboutWhisparr,
            includeTMDBMovies: tmdbEnabled && radarr.isConfigured,
            includeTMDBSeries: tmdbEnabled && sonarr.isConfigured
        )

        let invoke: @Sendable (String, JSONValue) async throws -> ToolCallOutput = { name, args in
            try await backend.callTool(name: name, arguments: args)
        }

        let provider: LLMProvider
        switch chatProvider {
        case .foundationModels:
            if #available(macOS 26.0, iOS 26.0, *) {
                provider = FoundationModelsProvider(invokeTool: invoke)
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
        return vm
    }
}
