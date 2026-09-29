import Foundation

/// UserDefaults keys mirrored via iCloud KVS; anything unlisted stays device-local.
/// Secrets sync via iCloud Keychain instead.
nonisolated enum SyncedKeys {
    static let all: Set<String> = {
        var keys: Set<String> = [
            "ArrBarr.notifyRadarr", "ArrBarr.notifySonarr", "ArrBarr.notifyLidarr",
            "ArrBarr.notificationSoundName",
            "ArrBarr.blurWhisparrPosters", "ArrBarr.whisparrAgeConfirmed",
            "ArrBarr.showWatchedIndicator",
            "ArrBarr.aiKnowsAboutWhisparr",
            "ArrBarr.arrOrder", "ArrBarr.showTonight", "ArrBarr.showNeedsYou",
            "ArrBarr.tonightVisibleCount",
            "ArrBarr.aiEnabled", "ArrBarr.chatProvider", "ArrBarr.openai",
            "ArrBarr.collapsedArrs", "ArrBarr.queueTitleGrouping",
            "ArrBarr.mediaServer", "ArrBarr.prowlarr",
        ]
        for kind in ServiceKind.allCases {
            keys.insert("ArrBarr.config.\(kind.rawValue)")
        }
        return keys
    }()

    static func isSynced(_ key: String) -> Bool { all.contains(key) }
}
