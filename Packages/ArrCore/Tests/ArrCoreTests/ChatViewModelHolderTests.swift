import Testing
import Foundation
@testable import ArrCore

/// The signature decides whether the chat view model is rebuilt. It must cover
/// every input `ChatViewModelFactory.make` branches on — demo mode and
/// `aiEnabled` were missing, so toggling demo at runtime left the pre-demo
/// provider in place whenever the two profiles agreed on everything else.
@Suite("ChatViewModelHolder signature", .serialized)
@MainActor
struct ChatViewModelHolderTests {
    /// Demo flag lives in `.standard`; restore it so suites stay independent.
    private func withDemoFlag(_ on: Bool, _ body: () throws -> Void) rethrows {
        let previous = UserDefaults.standard.bool(forKey: DemoMode.key)
        UserDefaults.standard.set(on, forKey: DemoMode.key)
        defer { UserDefaults.standard.set(previous, forKey: DemoMode.key) }
        try body()
    }

    /// Never `ConfigStore()`: that is the app's own App Group suite and Keychain.
    private static func store() -> ConfigStore {
        ConfigStore(defaults: TestDefaults.suite("ArrCoreTests.chatHolder.\(UUID().uuidString)"), secrets: InMemorySecretStore())
    }

    @Test("demo mode changes the signature with everything else held constant")
    func demoModeIsASignatureInput() throws {
        let store = Self.store()

        var offSignature = ""
        withDemoFlag(false) { offSignature = ChatViewModelHolder.signature(store: store) }

        var onSignature = ""
        withDemoFlag(true) { onSignature = ChatViewModelHolder.signature(store: store) }

        #expect(offSignature != onSignature)
    }

    @Test("aiEnabled changes the signature")
    func aiEnabledIsASignatureInput() {
        let store = Self.store()

        store.aiEnabled = false
        let disabled = ChatViewModelHolder.signature(store: store)

        store.aiEnabled = true
        let enabled = ChatViewModelHolder.signature(store: store)

        #expect(disabled != enabled)
    }

    @Test("an unchanged store yields a stable signature")
    func signatureIsStable() {
        let store = Self.store()
        #expect(ChatViewModelHolder.signature(store: store) == ChatViewModelHolder.signature(store: store))
    }
}
