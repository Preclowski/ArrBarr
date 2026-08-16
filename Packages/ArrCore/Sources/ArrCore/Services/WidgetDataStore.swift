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
        #if DEBUG
        if let dir = testSnapshotDirectory() { return [dir.appendingPathComponent(snapshotFile)] }
        #endif
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
        // The remembered location only counts while it is still one of the
        // candidates. Prepending it unconditionally let it outlive the list it
        // came from — which is how a write could land somewhere the current
        // candidates don't even mention (a test redirected to a temp directory
        // still wrote to the previously-remembered path).
        guard let preferred, candidates.contains(preferred) else { return candidates }
        return [preferred] + candidates.filter { $0 != preferred }
    }

    private static let snapshotLog = Logger(subsystem: AppLog.subsystem, category: "Snapshot")

    #if DEBUG
    /// Where the snapshot goes while a test bundle is loaded.
    ///
    /// Without this the suite writes into the user's *real* App Group
    /// container and `~/Library/Application Support` — running the tests left
    /// files in both. It also drags a system daemon into every run: the group
    /// container is resolved through containermanagerd, and a run of this
    /// suite once sat blocked on that path for 15+ minutes with the whole
    /// process idle. Tests have no business touching either location, so in a
    /// test process they don't.
    ///
    /// Set explicitly by a test that wants to inspect the file; otherwise a
    /// per-process temp directory, chosen once.
    nonisolated(unsafe) static var snapshotDirectoryOverrideForTesting: URL?
    /// Resolved once per process. `.some(nil)` is the answer "not a test
    /// process" — worth remembering too, or a Debug build of the app would
    /// re-scan every bundle and every argument on each refresh.
    private nonisolated(unsafe) static var cachedTestDirectory: URL??

    /// Four markers because no single one covers both runners. Under Xcode's
    /// XCTest host the class and the env vars are there; under SwiftPM the
    /// process is `swiftpm-testing-helper`, which loads swift-testing (no
    /// XCTest), sets no test env var, and does not even list the `.xctest`
    /// bundle in `allBundles` — only its argv names it. The first three checks
    /// were all present and all silently false here, so the suite kept writing
    /// into the real container.
    private static func isRunningUnderTests() -> Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) { return true }
        return ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
    }

    private static func testSnapshotDirectory() -> URL? {
        if let explicit = snapshotDirectoryOverrideForTesting { return explicit }
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        if let cached = cachedTestDirectory { return cached }
        guard Self.isRunningUnderTests() else {
            cachedTestDirectory = .some(nil)
            return nil
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArrBarrTestSnapshots-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cachedTestDirectory = dir
        return dir
    }
    #endif

    /// Snapshot writes run here, never on the caller's thread.
    ///
    /// `saveUpcoming` is called from `QueueViewModel.commitUpcoming` on the
    /// main actor, and a file write is not the bounded operation it looks
    /// like: the preferred destination is an App Group container, whose
    /// resolution goes through a system daemon that can stall. When it did,
    /// the main thread sat in `Data.write` at 0% CPU indefinitely — in a test
    /// run that's a hung suite, in the app it's a frozen UI. Serial, so
    /// snapshots still land in the order they were produced.
    private static let snapshotQueue = DispatchQueue(
        label: "pl.incred.ArrBarr.upcoming-snapshot", qos: .utility)

    #if DEBUG
    /// Parks the snapshot queue until the semaphore is signalled, so a test can
    /// hold the write hostage and prove the caller still returns. Without this
    /// the "doesn't block" test is vacuous — a *failing* write returns fast
    /// too, so it would pass against the very code that could hang.
    static func blockSnapshotQueueForTesting(until signal: DispatchSemaphore) {
        snapshotQueue.async { signal.wait() }
    }
    #endif

    /// Persist the last-known "Upcoming" calendar so it shows immediately on
    /// cold start — even when the arrs are unreachable (away from the home LAN).
    /// Air dates for the week ahead are stable, so a stale snapshot is genuinely
    /// useful offline; the live fetch replaces it the moment a refresh succeeds.
    ///
    /// An atomic file rather than `UserDefaults`, which buffers writes and may
    /// not flush before a hard kill — and this app does get hard-killed.
    ///
    /// The encode happens here, on the caller, so the snapshot matches the
    /// array as it was at this moment; the *write* is handed to
    /// `snapshotQueue` and never blocks the refresh. The narrow cost is a
    /// hard kill in the moment between the two losing one snapshot — this is
    /// a cache that every refresh rewrites, which is a far better trade than
    /// a UI that can freeze on a stalled container.
    public static func saveUpcoming(_ items: [UpcomingItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        snapshotQueue.async { writeSnapshot(data) }
    }

    /// Blocking half of `saveUpcoming`, off the caller's thread.
    private static func writeSnapshot(_ data: Data) {
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

    /// The read, off the caller's thread — the counterpart of `saveUpcoming`,
    /// and for the same reason: this resolves the same App Group container,
    /// and the app's cold start is a worse place to stall than a refresh. The
    /// widget's `TimelineProvider` keeps using the synchronous form; it runs
    /// in its own extension process with nothing to freeze.
    public static func loadUpcomingAsync() async -> [UpcomingItem] {
        await withCheckedContinuation { continuation in
            snapshotQueue.async { continuation.resume(returning: loadUpcoming()) }
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
