import Testing
@testable import ArrCore

@Suite("SyncedKeys")
struct SyncedKeysSuite {
    @Test("Includes cross-platform prefs and all service configs")
    func includesExpected() {
        #expect(SyncedKeys.all.contains("ArrBarr.config.radarr"))
        #expect(SyncedKeys.all.contains("ArrBarr.arrOrder"))
        #expect(SyncedKeys.all.contains("ArrBarr.whisparrAgeConfirmed"))
        #expect(SyncedKeys.all.contains("ArrBarr.openai"))
    }

    @Test("Excludes platform-specific, MCP, and one-shot keys")
    func excludesLocal() {
        for k in ["ArrBarr.foregroundInterval", "ArrBarr.backgroundInterval",
                  "ArrBarr.fontScale", "ArrBarr.launchAtLogin", "ArrBarr.appLanguage",
                  "ArrBarr.appearance", "ArrBarr.showIndexerIssues",
                  "ArrBarr.mcpEnabled", "ArrBarr.mcpHostPort",
                  "ArrBarr.welcomeSeenVersion", "ArrBarr.groupMigrationDone",
                  "ArrBarr.secretsMigratedToKeychain"] {
            #expect(!SyncedKeys.all.contains(k))
        }
    }

    @Test("isSynced matches membership")
    func isSyncedMatches() {
        #expect(SyncedKeys.isSynced("ArrBarr.arrOrder"))
        #expect(!SyncedKeys.isSynced("ArrBarr.fontScale"))
    }
}
