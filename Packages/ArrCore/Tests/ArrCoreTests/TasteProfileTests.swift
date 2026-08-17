import Foundation
import Testing
@testable import ArrCore

@Suite("Taste profile store")
struct TasteProfileStoreTests {

    private func freshStore() -> TasteProfileStore {
        let suite = "TasteProfileTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return TasteProfileStore(defaults: defaults)
    }

    @Test("promptBlock is nil when empty or disabled — an absent profile costs zero tokens")
    func promptBlockGating() {
        let store = freshStore()
        #expect(store.promptBlock() == nil)
        store.setParagraph("Leans toward slow-burn sci-fi.")
        #expect(store.promptBlock()?.contains("slow-burn sci-fi") == true)
        store.setUseInChat(false)
        #expect(store.promptBlock() == nil)
    }

    @Test("The user's own note rides along and survives without a paragraph")
    func userNoteRides() {
        let store = freshStore()
        store.setUserNote("no musicals")
        #expect(store.promptBlock()?.contains("no musicals") == true)
        store.setParagraph("Likes noir.")
        let block = store.promptBlock()
        #expect(block?.contains("Likes noir.") == true)
        #expect(block?.contains("no musicals") == true)
    }

    @Test("Clearing the paragraph clears the timestamp too")
    func clearingParagraph() {
        let store = freshStore()
        store.setParagraph("X")
        #expect(store.updatedAt != nil)
        store.setParagraph(nil)
        #expect(store.updatedAt == nil)
        #expect(store.paragraph == nil)
    }
}

@Suite("Taste profile generation prompt")
struct TasteProfilePromptTests {

    @Test("The prompt carries every signal section it was given, and only those")
    @MainActor
    func promptSections() {
        let prompt = TasteProfileGenerator.buildPrompt(
            kept: ["Sicario (2015)"], skipped: ["La La Land (2016)"],
            vetoed: [], watched: ["Severance (2022)"],
            languageName: "Polish"
        )
        #expect(prompt.contains("Sicario"))
        #expect(prompt.contains("La La Land"))
        #expect(prompt.contains("Severance"))
        #expect(!prompt.contains("REJECTED"), "an empty section must not appear")
        #expect(prompt.contains("Polish"))
    }
}
