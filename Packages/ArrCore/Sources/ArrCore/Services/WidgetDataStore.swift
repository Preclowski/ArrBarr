import Foundation
import os

/// App Group suite shared with the widget extension. `nonisolated`: `TimelineProvider` calls it off-main.
nonisolated public enum WidgetDataStore {
    /// iOS form; macOS under app-sandbox would need the team-id-prefixed identifier.
    nonisolated public static let appGroupSuiteName = "group.pl.incred.ArrBarr"

    nonisolated public static func groupDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupSuiteName)
    }

    // MARK: - Upcoming snapshot

    private static let snapshotFile = "upcoming-snapshot.json"

    /// Most-preferred first. The App Group can't be probed: on macOS (no entitlement) `containerURL` returns a path
    /// and `createDirectory` succeeds, but the write is denied — so only a successful write counts.
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

    /// The location that last accepted a write, tried first so an unreachable App Group costs one failure per process.
    private nonisolated(unsafe) static var writableSnapshotURL: URL?
    private static let snapshotLock = NSLock()

    private static func orderedSnapshotCandidates() -> [URL] {
        snapshotLock.lock()
        let preferred = writableSnapshotURL
        snapshotLock.unlock()
        let candidates = snapshotCandidates()
        // Only while it is still a candidate, or a test's redirected write could land in the old path.
        guard let preferred, candidates.contains(preferred) else { return candidates }
        return [preferred] + candidates.filter { $0 != preferred }
    }

    private static let snapshotLog = Logger(category: "Snapshot")

    #if DEBUG
    /// Tests must not touch the real App Group (resolved via containermanagerd, which once stalled a run 15+ min)
    /// or Application Support. Set by a test that inspects the file; otherwise a per-process temp directory.
    nonisolated(unsafe) static var snapshotDirectoryOverrideForTesting: URL?
    /// `.some(nil)` means "not a test process", cached so the app doesn't rescan bundles on every refresh.
    private nonisolated(unsafe) static var cachedTestDirectory: URL??

    /// No single marker covers both runners: SwiftPM's `swiftpm-testing-helper` loads no XCTest, sets no env var
    /// and doesn't list the `.xctest` bundle — only argv names it.
    private static func isRunningUnderTests() -> Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) { return true }
        return ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
    }

    static func testSnapshotDirectory() -> URL? {
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

    /// App Group resolution goes through a system daemon that can stall, which froze the main thread in `Data.write`.
    /// Serial, so snapshots land in order.
    private static let snapshotQueue = DispatchQueue(
        label: "pl.incred.ArrBarr.upcoming-snapshot", qos: .utility)

    #if DEBUG
    /// Lets a test hold the write and prove the caller still returns; a failing write returns fast too.
    // periphery:ignore
    static func blockSnapshotQueueForTesting(until signal: DispatchSemaphore) {
        snapshotQueue.async { signal.wait() }
    }
    #endif

    /// Last-known Upcoming calendar for cold start and offline use. An atomic file, not `UserDefaults`, which may
    /// not flush before a hard kill. Encoded on the caller; the write goes to `snapshotQueue`.
    public static func saveUpcoming(_ items: [UpcomingItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        snapshotQueue.async { writeSnapshot(data) }
    }

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

    /// Off the caller's thread for the same App Group stall; the widget keeps the synchronous form.
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

    /// Returns an empty config if the group suite is unavailable or the app hasn't migrated yet.
    public static func serviceConfig(_ kind: ServiceKind) -> ServiceConfig {
        guard let d = groupDefaults() else { return .empty }
        var cfg = ConfigStore.decodeServiceConfig(kind, from: d)
        // Ask ConfigStore rather than re-derive the backend: a diverging copy would read blank keys and show the widget unconfigured.
        let secrets = ConfigStore.makeDefaultSecretStore(defaults: d)
        cfg.apiKey = secrets.read(.apiKey(for: kind)) ?? cfg.apiKey
        cfg.password = secrets.read(.password(for: kind)) ?? cfg.password
        return cfg
    }

    // MARK: - Demo mirror

    /// The extension can't see the app's `UserDefaults.standard`, so the demo flag is mirrored into the group suite
    /// (kept in sync by `ConfigStore.useDemoStore`).
    static let demoActiveKey = "ArrBarr.demoActive"

    public static func setDemoActive(_ active: Bool) {
        groupDefaults()?.set(active, forKey: demoActiveKey)
    }

    public static var isDemoActive: Bool {
        groupDefaults()?.bool(forKey: demoActiveKey) ?? false
    }
}
