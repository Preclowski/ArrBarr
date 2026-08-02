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

    private static let snapshotFile = "upcoming-snapshot.json"

    /// Every place the snapshot may live, most-preferred first: the shared App
    /// Group container (so the widget can read it too), then the app's own
    /// Application Support. Both survive a restart.
    ///
    /// The App Group cannot be *probed*, only tried. macOS ships without the
    /// entitlement — there is no macOS widget to share with — and yet
    /// `containerURL` still returns a path there, and creating that directory
    /// SUCCEEDS while the write into it is denied by the sandbox. An earlier
    /// version treated `createDirectory` as the capability check, so it committed
    /// to the group and every refresh logged a permission failure — the fallback
    /// was unreachable and macOS kept no offline snapshot at all.
    private static func snapshotCandidates() -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupSuiteName) {
            urls.append(group.appendingPathComponent(snapshotFile))
        }
        if let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true) {
            urls.append(dir.appendingPathComponent(snapshotFile))
        }
        return urls
    }

    /// The candidate that last accepted a write, tried first from then on, so an
    /// unreachable App Group costs one failed write per process instead of one
    /// on every refresh. Still only a preference — if the remembered location
    /// starts failing, the others are tried again.
    private nonisolated(unsafe) static var writableSnapshotURL: URL?
    private static let snapshotLock = NSLock()

    private static func orderedSnapshotCandidates() -> [URL] {
        snapshotLock.lock()
        let preferred = writableSnapshotURL
        snapshotLock.unlock()
        let candidates = snapshotCandidates()
        guard let preferred else { return candidates }
        return [preferred] + candidates.filter { $0 != preferred }
    }

    private static let snapshotLog = Logger(subsystem: AppLog.subsystem, category: "Snapshot")

    /// Persist the last-known "Upcoming" calendar so it shows immediately on
    /// cold start — even when the arrs are unreachable (away from the home LAN).
    /// Air dates for the week ahead are stable, so a stale snapshot is genuinely
    /// useful offline; the live fetch replaces it the moment a refresh succeeds.
    ///
    /// An atomic file rather than `UserDefaults`, which buffers writes and may
    /// not flush before a hard kill — and this app does get hard-killed.
    public static func saveUpcoming(_ items: [UpcomingItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        var lastError: Error?
        for url in orderedSnapshotCandidates() {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                snapshotLock.lock()
                writableSnapshotURL = url
                snapshotLock.unlock()
                return
            } catch {
                lastError = error
            }
        }
        if let lastError {
            snapshotLog.error(
                "upcoming snapshot write failed: \(lastError.localizedDescription, privacy: .public)"
            )
        }
    }

    public static func loadUpcoming() -> [UpcomingItem] {
        for url in orderedSnapshotCandidates() {
            guard let data = try? Data(contentsOf: url),
                  let items = try? JSONDecoder().decode([UpcomingItem].self, from: data)
            else { continue }
            return items
        }
        return []
    }

    /// Reads a service config from the group suite and merges the secrets back
    /// in from wherever the app put them. Returns an empty (unconfigured) config
    /// if the group suite is unavailable or the app hasn't migrated yet.
    public static func serviceConfig(_ kind: ServiceKind) -> ServiceConfig {
        guard let d = groupDefaults() else { return .empty }
        var cfg = ConfigStore.decodeServiceConfig(kind, from: d)
        // Ask ConfigStore for the backend rather than re-deriving it: the two
        // must agree exactly, and they last disagreed when only this side still
        // required an App Store build. A Developer ID build writes to the shared
        // Keychain, so a copy of the old rule here would read blank keys and the
        // widget would silently render as unconfigured.
        let secrets = ConfigStore.makeDefaultSecretStore(defaults: d)
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
