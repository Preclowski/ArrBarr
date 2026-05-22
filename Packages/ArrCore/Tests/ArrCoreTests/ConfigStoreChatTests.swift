import Testing
import Foundation
@testable import ArrCore

@MainActor
@Suite("ConfigStore — chat & MCP")
struct ConfigStoreChatTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "ArrBarrTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("defaults: aiEnabled false, mcp empty")
    func defaults() {
        let d = freshDefaults()
        let store = ConfigStore(defaults: d)
        #expect(store.aiEnabled == false)
        #expect(store.mcp == .empty)
    }

    @Test("persists aiEnabled across instances")
    func persistChatEnabled() {
        let d = freshDefaults()
        do {
            let s = ConfigStore(defaults: d)
            s.aiEnabled = true
        }
        let s2 = ConfigStore(defaults: d)
        #expect(s2.aiEnabled == true)
    }

    @Test("persists mcp across instances")
    func persistMCP() {
        let d = freshDefaults()
        let cfg = MCPConfig(enabled: true, baseURL: "https://x/mcp", bearerToken: "tok")
        do {
            let s = ConfigStore(defaults: d)
            s.mcp = cfg
        }
        let s2 = ConfigStore(defaults: d)
        #expect(s2.mcp == cfg)
    }

    @Test("defaults: chatProvider foundationModels, openai empty")
    func defaultsProvider() {
        let d = freshDefaults()
        let store = ConfigStore(defaults: d)
        #expect(store.chatProvider == .foundationModels)
        #expect(store.openai == .empty)
    }

    @Test("persists chatProvider across instances")
    func persistChatProvider() {
        let d = freshDefaults()
        do {
            let s = ConfigStore(defaults: d)
            s.chatProvider = .openai
        }
        let s2 = ConfigStore(defaults: d)
        #expect(s2.chatProvider == .openai)
    }

    @Test("persists openai across instances")
    func persistOpenAI() {
        let d = freshDefaults()
        let cfg = OpenAIConfig(baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-or-abc", model: "openai/gpt-4o-mini")
        do {
            let s = ConfigStore(defaults: d)
            s.openai = cfg
        }
        let s2 = ConfigStore(defaults: d)
        #expect(s2.openai == cfg)
    }
}
