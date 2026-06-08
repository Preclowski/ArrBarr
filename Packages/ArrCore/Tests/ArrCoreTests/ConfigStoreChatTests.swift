import Testing
import Foundation
@testable import ArrCore

@MainActor
@Suite("ConfigStore — chat")
struct ConfigStoreChatTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "ArrBarrTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("defaults: aiEnabled false")
    func defaults() {
        let d = freshDefaults()
        let store = ConfigStore(defaults: d, secrets: InMemorySecretStore())
        #expect(store.aiEnabled == false)
    }

    @Test("persists aiEnabled across instances")
    func persistChatEnabled() {
        let d = freshDefaults()
        let secrets = InMemorySecretStore()
        do {
            let s = ConfigStore(defaults: d, secrets: secrets)
            s.aiEnabled = true
        }
        let s2 = ConfigStore(defaults: d, secrets: secrets)
        #expect(s2.aiEnabled == true)
    }

    @Test("defaults: chatProvider foundationModels (or openai when FM unsupported), openai empty")
    func defaultsProvider() {
        let d = freshDefaults()
        let store = ConfigStore(defaults: d, secrets: InMemorySecretStore())
        // Default is Apple Intelligence, but it's coerced to OpenAI on devices
        // that don't support Foundation Models so the Settings picker doesn't
        // visually lie (it hides the unsupported option).
        let expected: ChatProvider = FoundationModelsAvailability.isSupported ? .foundationModels : .openai
        #expect(store.chatProvider == expected)
        #expect(store.openai == .empty)
    }

    @Test("persists chatProvider across instances")
    func persistChatProvider() {
        let d = freshDefaults()
        let secrets = InMemorySecretStore()
        do {
            let s = ConfigStore(defaults: d, secrets: secrets)
            s.chatProvider = .openai
        }
        let s2 = ConfigStore(defaults: d, secrets: secrets)
        #expect(s2.chatProvider == .openai)
    }

    @Test("persists openai across instances")
    func persistOpenAI() {
        let d = freshDefaults()
        let secrets = InMemorySecretStore()
        let cfg = OpenAIConfig(baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-or-abc", model: "openai/gpt-4o-mini")
        do {
            let s = ConfigStore(defaults: d, secrets: secrets)
            s.openai = cfg
        }
        let s2 = ConfigStore(defaults: d, secrets: secrets)
        #expect(s2.openai == cfg)
    }
}
