import Foundation

/// The App Group suite shared between the host app and the widget extension,
/// plus extension-safe config reads. `nonisolated` throughout — a widget
/// `TimelineProvider` calls this from a background context.
public enum WidgetDataStore {
    /// iOS App Group identifier. (macOS, shipped later, needs the
    /// team-id-prefixed form under app-sandbox — handled when the macOS
    /// widget target is added.)
    public static let appGroupSuiteName = "group.com.preclowski.ArrBarr"

    public static func groupDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupSuiteName)
    }

    /// Reads a service config from the group suite and merges secrets back in
    /// from the Keychain (shared access group under APPSTORE). Returns an empty
    /// (unconfigured) config if the group suite is unavailable or the app
    /// hasn't migrated yet.
    public static func serviceConfig(_ kind: ServiceKind) -> ServiceConfig {
        guard let d = groupDefaults() else { return .empty }
        var cfg = ConfigStore.decodeServiceConfig(kind, from: d)
        // Match the app's secret backend: shared-group Keychain under APPSTORE,
        // otherwise the UserDefaults group suite (where the app stored them).
        let secrets: SecretStore = (AppCapabilities.isAppStore && AppCapabilities.keychainSharingAvailable)
            ? KeychainSecretStore()
            : UserDefaultsSecretStore(defaults: d)
        cfg.apiKey = secrets.read(.apiKey(for: kind)) ?? cfg.apiKey
        cfg.password = secrets.read(.password(for: kind)) ?? cfg.password
        return cfg
    }

    // MARK: - Demo mirror

    /// Mirror of the app's demo-mode flag, written into the group suite so the
    /// widget extension can detect it. `DemoMode.isActive` reads the *app's*
    /// `UserDefaults.standard`, which the extension (a separate bundle) can't
    /// see — and the demo suite is never the group suite — so without this
    /// mirror the widget would always render real data. The app keeps it in
    /// sync from its single demo chokepoint (`ConfigStore.useDemoStore`).
    static let demoActiveKey = "ArrBarr.demoActive"

    public static func setDemoActive(_ active: Bool) {
        groupDefaults()?.set(active, forKey: demoActiveKey)
    }

    /// True when the app is in demo mode (read from the group mirror).
    public static var isDemoActive: Bool {
        groupDefaults()?.bool(forKey: demoActiveKey) ?? false
    }
}
