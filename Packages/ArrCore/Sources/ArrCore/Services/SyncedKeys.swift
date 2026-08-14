import Foundation

/// The explicit opt-in allowlist of UserDefaults keys mirrored across devices
/// via iCloud KVS. Secrets are NOT here — they sync via iCloud Keychain. Keys
/// not listed (platform-specific prefs, MCP server, one-shot/migration flags)
/// stay device-local.
public enum SyncedKeys {
    public static let all: Set<String> = {
        var keys: Set<String> = [
            "ArrBarr.notifyRadarr", "ArrBarr.notifySonarr", "ArrBarr.notifyLidarr",
            "ArrBarr.notificationSoundName",
            "ArrBarr.blurWhisparrPosters", "ArrBarr.whisparrAgeConfirmed",
            "ArrBarr.aiKnowsAboutWhisparr",
            "ArrBarr.arrOrder", "ArrBarr.showTonight", "ArrBarr.showNeedsYou",
            "ArrBarr.tonightVisibleCount",
            "ArrBarr.aiEnabled", "ArrBarr.chatProvider", "ArrBarr.openai",
            "ArrBarr.collapsedArrs", "ArrBarr.queueTitleGrouping",
        ]
        for kind in ServiceKind.allCases {
            keys.insert("ArrBarr.config.\(kind.rawValue)")
        }
        return keys
    }()

    public static func isSynced(_ key: String) -> Bool { all.contains(key) }
}
