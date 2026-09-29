import Foundation
import MediaKit

enum ChatViewModelFactory {
    static func makePlaceholder() -> ChatViewModel {
        ChatViewModel(
            provider: UnavailableLLMProvider(),
            tools: [],
            invokeTool: { _, _ in ToolCallOutput(text: "") }
        )
    }

    static func make(
        sonarr: ServiceConfig,
        radarr: ServiceConfig,
        lidarr: ServiceConfig = .empty,
        whisparr: ServiceConfig = .empty,
        aiKnowsAboutWhisparr: Bool = false,
        tmdbApiKey: String = "",
        downloadClients: DownloadClientConfigs = .init(),
        mediaServer: MediaServerConfig = .empty,
        chatProvider: ChatProvider,
        openai: OpenAIConfig,
        appLanguage: String = "system"
    ) -> ChatViewModel {
        let replyLanguage = replyLanguageName(appLanguage: appLanguage)
        let backend = LocalToolBackend(
            sonarr: sonarr, radarr: radarr, lidarr: lidarr,
            whisparr: whisparr, aiKnowsAboutWhisparr: aiKnowsAboutWhisparr,
            tmdbApiKey: tmdbApiKey, downloadClients: downloadClients,
            mediaServer: mediaServer
        )

        // Warm the library snapshot so the first quiz call hits the cache and the prompt's
        // library-size line is populated before the first turn.
        Task.detached(priority: .utility) {
            if radarr.isConfigured { _ = await LibraryIndex.shared.movies(config: radarr) }
            if sonarr.isConfigured { _ = await LibraryIndex.shared.series(config: sonarr) }
        }

        let tmdbEnabled = !tmdbApiKey.isEmpty
        let llmTools = ChatToolCatalog.llmTools(
            includeSonarr: sonarr.isConfigured,
            includeRadarr: radarr.isConfigured,
            includeLidarr: lidarr.isConfigured,
            includeWhisparr: whisparr.isConfigured && aiKnowsAboutWhisparr,
            includeTMDBMovies: tmdbEnabled && radarr.isConfigured,
            includeTMDBSeries: tmdbEnabled && sonarr.isConfigured,
            includeMediaServer: mediaServer.isConfigured
        )

        let invoke: @Sendable (String, JSONValue) async throws -> ToolCallOutput = { name, args in
            try await backend.callTool(name: name, arguments: args)
        }

        // The FM path runs tools inside `DynamicMCPTool.call`, so the gate reaches back into a view model
        // that doesn't exist yet. A capture list copies the value, so it goes through a box filled afterwards.
        let vmRef = WeakChatViewModel()
        let confirm: @Sendable (ToolCall) async -> JSONValue? = { call in
            guard let vm = await vmRef.vm else { return nil }
            return await vm.awaitConfirm(call)
        }

        let provider: LLMProvider
        // Demo short-circuits both real backends: OpenAI needs a key and the on-device model can't see the canned arrs.
        if DemoMode.isActive {
            provider = DemoChatProvider()
            return ChatViewModel(provider: provider, tools: llmTools, invokeTool: invoke)
        }
        switch chatProvider {
        case .foundationModels:
            provider = FoundationModelsProvider(invokeTool: invoke, confirmDestructive: confirm)
        case .openai:
            if openai.isConfigured {
                provider = OpenAIProvider(config: openai, replyLanguage: replyLanguage)
            } else {
                provider = UnavailableLLMProvider()
            }
        }

        let vm = ChatViewModel(
            provider: provider,
            tools: llmTools,
            invokeTool: invoke,
            onToolCallStream: { name, arguments in
                guard name == "discover_in_quiz" else { return }
                Task { await backend.quizArgumentsStreamed(arguments) }
            },
            onTurnEnded: { Task { await backend.chatTurnEnded() } },
            onClear: { Task { await backend.resetConversation() } }
        )
        vmRef.vm = vm
        return vm
    }

    /// The system prompt wants an English language name ("pl" → "Polish").
    nonisolated static func replyLanguageName(appLanguage: String) -> String {
        let english = Locale(identifier: "en")
        if appLanguage == "system" {
            if let pref = Locale.preferredLanguages.first,
               let code = Locale(identifier: pref).language.languageCode?.identifier,
               let name = english.localizedString(forLanguageCode: code) {
                return name
            }
            return "the user's system language"
        }
        return english.localizedString(forLanguageCode: appLanguage) ?? "English"
    }
}

private final class WeakChatViewModel {
    weak var vm: ChatViewModel?
}
