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

    @Test("defaults: chatEnabled false, mcp empty")
    func defaults() {
        let d = freshDefaults()
        let store = ConfigStore(defaults: d)
        #expect(store.chatEnabled == false)
        #expect(store.mcp == .empty)
    }

    @Test("persists chatEnabled across instances")
    func persistChatEnabled() {
        let d = freshDefaults()
        do {
            let s = ConfigStore(defaults: d)
            s.chatEnabled = true
        }
        let s2 = ConfigStore(defaults: d)
        #expect(s2.chatEnabled == true)
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
}
