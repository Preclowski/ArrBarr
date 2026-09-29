import Foundation

/// UserDefaults keys mirrored via iCloud KVS; anything unlisted stays device-local.
/// Secrets sync via iCloud Keychain instead.
nonisolated enum SyncedKeys {
    static let all: Set<String> = {
        typealias Keys = ConfigStore.Keys
        var keys: Set<String> = [
            Keys.notifyRadarr, Keys.notifySonarr, Keys.notifyLidarr, Keys.notificationSoundName,
            Keys.blurWhisparrPosters, Keys.whisparrAgeConfirmed, Keys.showWatchedIndicator, Keys.aiKnowsAboutWhisparr,
            Keys.arrOrder, Keys.showTonight, Keys.showNeedsYou, Keys.tonightVisibleCount,
            Keys.aiEnabled, Keys.chatProvider, ConfigStore.openaiConfigKey,
            QueueUIState.collapsedArrsKey, QueueUIState.queueTitleGroupingKey,
            ConfigStore.mediaServerKey, ConfigStore.prowlarrKey,
        ]
        for kind in ServiceKind.allCases {
            keys.insert("ArrBarr.config.\(kind.rawValue)")
        }
        return keys
    }()

    static func isSynced(_ key: String) -> Bool { all.contains(key) }
}
