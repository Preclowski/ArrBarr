import SwiftUI
import FoundationModels

extension SettingsView {
    @ViewBuilder
    var aiSection: some View {
        Section {
            Toggle(isOn: Bindable(configStore).aiEnabled) { Text("settings.enableAi.button", bundle: .module) }
        } header: { Text("settings.assistant.button", bundle: .module) }
        if configStore.aiEnabled {
            Section {
                Picker(selection: Bindable(configStore).chatProvider) {
                    ForEach(ChatProvider.allCases.filter {
                        $0 != .foundationModels || FoundationModelsAvailability.isOffered
                    }) { p in
                        (p == .foundationModels ? FoundationModelsAvailability.pickerLabel : Text(p.displayName)).tag(p)
                    }
                } label: { Text("settings.aiProvider.button", bundle: .module) }
                if configStore.chatProvider == .openai {
                    TextField(text: Bindable(configStore).openai.baseURL,
                              prompt: Text(verbatim: "https://api.openai.com/v1")) {
                        Text("settings.apiBaseUrl.button", bundle: .module)
                    }
                    .urlField()
                    SecureField(text: Bindable(configStore).openai.apiKey) { Text("settings.apiKey2.button", bundle: .module) }
                        .apiKeyField()
                    // A bare Form TextField hides its label once it has a value.
                    LabeledContent {
                        // Empty title: LabeledContent supplies the label; a second one renders twice.
                        TextField("", text: Bindable(configStore).openai.model,
                                  prompt: Text(verbatim: "gpt-4o-mini"))
                        #if os(iOS)
                        .multilineTextAlignment(.trailing)
                        #endif
                        .technicalField()
                    } label: {
                        Text("settings.model.button", bundle: .module)
                    }
                    if !configStore.openai.apiKey.isEmpty && !configStore.openai.baseURL.isEmpty {
                        ApiKeyTestButton(test: {
                            try await OpenAIProvider(config: configStore.openai).testConnection()
                        }, service: .openai)
                    }
                    if !configStore.openai.isConfigured {
                        Label {
                            Text("settings.addBaseUrlApi.tooltip", bundle: .module)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    Text("settings.theModelMustSupport.tooltip", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if configStore.chatProvider == .foundationModels {
                    #if os(macOS)
                    if #unavailable(macOS 26.0) {
                        Label { Text("settings.appleIntelligenceRequiresMacos.tooltip", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    #else
                    if #unavailable(iOS 26.0) {
                        Label { Text("settings.appleIntelligenceRequiresIos.tooltip", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    #endif
                }
                if configStore.whisparr.isConfigured {
                    Toggle(isOn: Bindable(configStore).aiKnowsAboutWhisparr) { Text("settings.aiKnowsAboutWhisparr.button", bundle: .module) }
                }
            }
        }
    }

    /// Under General, not AI: the TMDB key also powers cast strips and discovery.
    var tmdbSection: some View {
        Section {
            SecureField(text: Bindable(configStore).tmdbApiKey,
                        prompt: Text(verbatim: "v4 Read Access Token")) {
                Text("settings.tmdbReadAccessToken.button", bundle: .module)
            }
            .apiKeyField()
            if !configStore.tmdbApiKey.isEmpty {
                ApiKeyTestButton(test: {
                    try await configStore.tmdbClient.testConnection()
                }, service: .tmdb)
            }
            if let url = URL(string: "https://www.themoviedb.org/settings/api") {
                Link(destination: url) {
                    Label { Text("settings.getAFreeTmdb.button", bundle: .module) } icon: { Image(systemName: "link") }
                        .font(.caption)
                }
            }
        } header: {
            Text("settings.discovery.button", bundle: .module)
        } footer: {
            Text(configStore.tmdbEnabled
                 ? String(localized: "settings.chatCanSearchBy.tooltip", bundle: .module)
                 : String(localized: "settings.addATmdbKey.tooltip", bundle: .module))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Prowlarr only names indexers for manual-search rows. No `ServiceKind`, so the
    /// fields are spelled out here, matching `ServiceFields`.
    @ViewBuilder
    var prowlarrFields: some View {
        Toggle(isOn: Bindable(configStore).prowlarr.enabled) {
            Text("settings.enabled.button", bundle: .module)
        }
        if configStore.prowlarr.enabled {
            TextField(text: prowlarrURLBinding,
                      prompt: Text(verbatim: "http://192.168.1.10:9696")) {
                Text("settings.url.label", bundle: .module)
            }
            .urlField()
            SecureField(text: Bindable(configStore).prowlarr.apiKey,
                        prompt: Text("settings.pasteYourApiKey.button", bundle: .module)) {
                Text("settings.apiKey.button", bundle: .module)
            }
            .apiKeyField()
            if let reason = prowlarrIncompleteReason {
                Label {
                    Text(verbatim: reason)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if configStore.prowlarr.isConfigured {
                ApiKeyTestButton(test: { try await configStore.testProwlarr() },
                                 service: .prowlarr)
            }
        }
    }

    /// A URL pasted from Prowlarr's address bar carries a `#/…` route `URL(string:)` rejects.
    private var prowlarrURLBinding: Binding<String> {
        Binding(
            get: { configStore.prowlarr.baseURL },
            set: { configStore.prowlarr.baseURL = ServiceFields.sanitizedBaseURL($0) }
        )
    }

    private var prowlarrIncompleteReason: String? {
        guard configStore.prowlarr.enabled else { return nil }
        if !configStore.prowlarr.isConfigured {
            return String(localized: "settings.enterAValidUrl.tooltip", bundle: .module)
        }
        if configStore.prowlarr.apiKey.isEmpty {
            return String(localized: "settings.apiKeyIsRequired.tooltip", bundle: .module)
        }
        return nil
    }

    var prowlarrRowLabel: some View {
        HStack(spacing: 10) {
            #if os(macOS)
            // Invisible grip keeps the leading edge aligned with the arr cards at any text size.
            Image(systemName: "line.3.horizontal")
                .scaledFont(size: 11)
                .hidden()
                .accessibilityHidden(true)
            #endif
            ServiceIcon(prowlarr: 18)
                .accessibilityHidden(true)
            Text(verbatim: "Prowlarr")
                .foregroundStyle(.primary)
            Spacer()
            if configStore.prowlarr.isConfigured {
                ConnectionStatusDot(service: .prowlarr)
            }
            #if os(macOS)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            #endif
        }
        .contentShape(Rectangle())
    }

    /// No brand asset ships for Prowlarr, so row and header share an SF Symbol.
    var prowlarrHeader: some View {
        HStack(spacing: 6) {
            ServiceIcon(prowlarr: 12)
                .accessibilityHidden(true)
            Text(verbatim: "Prowlarr")
        }
    }
}

private extension FoundationModelsAvailability {
    /// The picker label, naming why the model can't answer yet.
    static var pickerLabel: Text {
        switch SystemLanguageModel.default.availability {
        case .unavailable(.modelNotReady):
            return Text("settings.aiProvider.appleIntelligence.downloading", bundle: .module)
        case .unavailable(.appleIntelligenceNotEnabled):
            return Text("settings.aiProvider.appleIntelligence.off", bundle: .module)
        default:
            return Text(ChatProvider.foundationModels.displayName)
        }
    }
}
