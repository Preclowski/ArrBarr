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
        downloadClients: DownloadClientConfigs = .init(),
        mediaServer: MediaServerConfig = .empty,
        chatProvider: ChatProvider,
        openai: OpenAIConfig,
        appLanguage: String = "system"
    ) -> ChatViewModel {
        let replyLanguage = replyLanguageName(appLanguage: appLanguage)
        let backend: ToolBackend = LocalToolBackend(
            sonarr: sonarr, radarr: radarr, lidarr: lidarr,
            whisparr: whisparr, aiKnowsAboutWhisparr: aiKnowsAboutWhisparr,
            tmdbApiKey: tmdbApiKey, downloadClients: downloadClients,
            mediaServer: mediaServer
        )

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

        // The FM path drives tool execution from inside its own
        // `DynamicMCPTool.call`, so the destructive-tool gate has to
        // reach back into the view-model from there. ChatViewModel
        // doesn't exist yet at this point, so we capture a `weak`
        // reference through a holder that gets back-filled after the
        // VM is constructed.
        var vmRef: ChatViewModel? = nil
        let confirm: @Sendable (ToolCall) async -> JSONValue? = { [weak vmRef] call in
            guard let vm = vmRef else { return nil }
            return await vm.awaitConfirm(call)
        }

        let provider: LLMProvider
        // Demo mode: short-circuit the provider switch before either real
        // backend (OpenAI / FoundationModels) is consulted. The OpenAI
        // path would fail without a key; the FM path would either be
        // unavailable on older OSes or hit the real on-device model,
        // which can't see our canned arrs anyway. DemoChatProvider
        // returns pre-executed `suggest_titles`-shaped results so the
        // existing chat pipeline renders rich cards without any other
        // changes downstream.
        if DemoMode.isActive {
            provider = DemoChatProvider()
            let vm = ChatViewModel(provider: provider, tools: llmTools, invokeTool: invoke)
            vmRef = vm
            return vm
        }
        switch chatProvider {
        case .foundationModels:
            if #available(macOS 26.0, iOS 26.0, *) {
                provider = FoundationModelsProvider(invokeTool: invoke, confirmDestructive: confirm)
            } else {
                provider = UnavailableLLMProvider()
            }
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
            invokeTool: invoke
        )
        vmRef = vm
        return vm
    }

    /// A bare provider for one-off, tool-less jobs — taste-profile generation.
    /// Same provider selection as the chat, minus tools and the demo shortcut,
    /// so the paragraph is produced by whatever model the user already trusts.
    public static func makeBareProvider(
        chatProvider: ChatProvider,
        openai: OpenAIConfig,
        appLanguage: String = "system"
    ) -> LLMProvider {
        switch chatProvider {
        case .foundationModels:
            if #available(macOS 26.0, iOS 26.0, *) {
                return FoundationModelsProvider(
                    invokeTool: { _, _ in ToolCallOutput(text: "") },
                    confirmDestructive: { _ in nil }
                )
            }
            return UnavailableLLMProvider()
        case .openai:
            guard openai.isConfigured else { return UnavailableLLMProvider() }
            return OpenAIProvider(config: openai,
                                  replyLanguage: replyLanguageName(appLanguage: appLanguage))
        }
    }

    /// Maps the app's language setting to an English language name for the
    /// system prompt (e.g. "pl" → "Polish"). For "system", resolves the OS's
    /// current preferred language; falls back gracefully when unknown.
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
