import Foundation
import Testing
@testable import ArrCore

@Suite("Standing preferences store")
struct TasteProfileStoreTests {

    private func freshStore() -> TasteProfileStore {
        let suite = "TasteProfileTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return TasteProfileStore(defaults: defaults)
    }

    @Test("promptBlock is nil when empty or disabled — an absent note costs zero tokens")
    func promptBlockGating() {
        let store = freshStore()
        #expect(store.promptBlock() == nil)
        store.setUserNote("no musicals")
        #expect(store.promptBlock()?.contains("no musicals") == true)
        store.setUseInChat(false)
        #expect(store.promptBlock() == nil)
    }

    @Test("Whitespace-only notes count as empty")
    func whitespaceNote() {
        let store = freshStore()
        store.setUserNote("   \n ")
        #expect(store.promptBlock() == nil)
    }

    @Test("The note survives a store reload from the same defaults")
    func persistsAcrossReload() {
        let suite = "TasteProfileTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        TasteProfileStore(defaults: defaults).setUserNote("subtitles fine")
        #expect(TasteProfileStore(defaults: defaults).userNote == "subtitles fine")
    }
}
