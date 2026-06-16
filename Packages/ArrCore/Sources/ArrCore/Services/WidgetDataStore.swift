import Foundation
import os

/// The App Group suite shared between the host app and the widget extension,
/// plus extension-safe config reads. `nonisolated` throughout — a widget
/// `TimelineProvider` calls this from a background context.
public enum WidgetDataStore {
    /// iOS App Group identifier. (macOS, shipped later, needs the
    /// team-id-prefixed form under app-sandbox — handled when the macOS
    /// widget target is added.)
    public static let appGroupSuiteName = "group.pl.incred.ArrBarr"

    public static func groupDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupSuiteName)
    }

    // MARK: - Upcoming snapshot

    /// Last-known "Upcoming" calendar, cached in the App Group so it survives a
    /// relaunch and shows immediately on cold start — even when the arrs are
    /// unreachable (away from the home LAN). Calendar entries are stable
    /// (air dates for the week ahead), so a stale snapshot is genuinely useful
    /// offline; the live fetch replaces it the moment a refresh succeeds.
    /// On-disk JSON file rather than UserDefaults: `UserDefaults` buffers writes
    /// and may not flush before a hard kill / crash, so the snapshot could be
    /// lost across a restart. An atomic file write lands on disk immediately and
    /// survives any termination. Prefers the shared App Group container (so the
    /// widget can read it too); falls back to the app's own Application Support
    /// — both persist across restarts.
    private static func upcomingSnapshotURL() -> URL? {
        let fm = FileManager.default
        // App Group container (shared with the widget) ONLY when its directory
        // actually exists or can be created. On macOS the group isn't
        // provisioned yet (no entitlement), yet `containerURL` still hands back a
        // path whose directory is MISSING — an atomic write there silently fails.
        // So verify we can ensure the directory; otherwise fall back to the app's
        // own Application Support (always writable, survives restarts).
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupSuiteName),
           (try? fm.createDirectory(at: group, withIntermediateDirectories: true)) != nil {
            return group.appendingPathComponent("upcoming-snapshot.json")
        }
        guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("upcoming-snapshot.json")
    }

    private static let snapshotLog = Logger(subsystem: AppLog.subsystem, category: "Snapshot")

    public static func saveUpcoming(_ items: [UpcomingItem]) {
        guard let url = upcomingSnapshotURL(), let data = try? JSONEncoder().encode(items) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            snapshotLog.error("upcoming snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func loadUpcoming() -> [UpcomingItem] {
        guard let url = upcomingSnapshotURL(),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([UpcomingItem].self, from: data)
        else { return [] }
        return items
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
