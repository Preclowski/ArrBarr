import Foundation
import Observation
import os

/// Abstraction over `NSUbiquitousKeyValueStore` so the coordinator is testable
/// without a real iCloud account.
public protocol KeyValueSyncing: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueSyncing {}

/// Mirrors the `SyncedKeys` allowlist between UserDefaults (source of truth) and
/// iCloud KVS. Compiled everywhere for tests; started only under `#if APPSTORE`.
@Observable
public final class KVSyncCoordinator {
    private let defaults: UserDefaults
    private let kv: KeyValueSyncing
    private let reload: () -> Void
    private var isApplyingRemote = false
    private var observers: [NSObjectProtocol] = []

    public private(set) var lastSyncDate: Date?
    public private(set) var lastError: String?
    public private(set) var isRunning: Bool = false

    /// Stored and observed so Settings refreshes live on iCloud sign-in/out.
    public private(set) var accountAvailable: Bool

    /// Injectable so tests can drive sign-in/out.
    private let identityCheck: @Sendable () -> Bool

    /// Keys are logged by name only: allowlisted setting names, never values.
    private static let log = Logger(category: "KVSync")

    /// Outside `observers` so `accountAvailable` stays current regardless of `isRunning`.
    private var identityObserver: NSObjectProtocol?

    public init(defaults: UserDefaults, kv: KeyValueSyncing, reload: @escaping () -> Void,
                identityCheck: @escaping @Sendable () -> Bool
                    = { FileManager.default.ubiquityIdentityToken != nil }) {
        self.defaults = defaults
        self.kv = kv
        self.reload = reload
        self.identityCheck = identityCheck
        self.accountAvailable = identityCheck()
        // The notification can arrive on any thread.
        identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccountAvailability() }
        }
    }

    public func start() {
        refreshAccountAvailability()
        let kvObs = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv as AnyObject, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let changed = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String])
                ?? Array(SyncedKeys.all)
            MainActor.assumeIsolated {
                guard let self else { return }
                if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
                    // The only failure iCloud reports; sync stops until the user frees space.
                    Self.log.error("inbound change rejected: iCloud KVS quota exceeded")
                    self.lastError = String(localized: "settings.icloudStorageIsFull.tooltip", bundle: .module)
                } else {
                    self.lastError = nil
                }
                self.applyFromKV(keys: changed)
            }
        }
        let defObs = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isApplyingRemote else { return }
                self.pushAllToKV()
            }
        }
        observers = [kvObs, defObs]
        applyFromKV(keys: Array(SyncedKeys.all))
        pushAllToKV()
        kv.synchronize()
        isRunning = true
        lastError = nil
        Self.log.notice(
            "iCloud sync started (account \(self.accountAvailable ? "available" : "unavailable", privacy: .public), \(SyncedKeys.all.count, privacy: .public) keys mirrored)"
        )
    }

    /// Existing KVS/Keychain data is left intact.
    public func stop() {
        refreshAccountAvailability()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        isRunning = false
        Self.log.notice("iCloud sync stopped")
    }

    private func refreshAccountAvailability() {
        accountAvailable = identityCheck()
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            guard !isRunning else { return }
            start()
        } else {
            guard isRunning else { return }
            stop()
        }
    }

    public func pushAllToKV() {
        for key in SyncedKeys.all {
            if let value = defaults.object(forKey: key) {
                // Re-pushing an identical value bounces between devices and burns KVS quota.
                if !Self.kvEqual(kv.object(forKey: key), value) {
                    kv.set(value, forKey: key)
                }
            }
        }
        if accountAvailable { lastSyncDate = Date() }
    }

    /// Plist-type equality, used to suppress pushes that would bounce between devices.
    private static func kvEqual(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil, b == nil { return true }
        guard let a, let b else { return false }
        return (a as AnyObject).isEqual(b)
    }

    /// Outbound observation is suppressed while applying.
    public func applyFromKV(keys: [String]) {
        isApplyingRemote = true
        var applied: [String] = []
        for key in keys where SyncedKeys.isSynced(key) {
            if let value = kv.object(forKey: key) {
                defaults.set(value, forKey: key)
                applied.append(key)
            }
        }
        if !applied.isEmpty {
            Self.log.debug("applied \(applied.count, privacy: .public) inbound keys: \(applied.joined(separator: ", "), privacy: .public)")
        }
        reload()
        // Reset on a later tick: the outbound observer (queue: .main) must still
        // see `isApplyingRemote == true` for the sets above.
        DispatchQueue.main.async { [weak self] in self?.isApplyingRemote = false }
    }

    /// Test seam: simulate the outbound observer for one key.
    // periphery:ignore
    public func observeDefault(_ key: String) {
        guard !isApplyingRemote, SyncedKeys.isSynced(key) else { return }
        if let value = defaults.object(forKey: key) { kv.set(value, forKey: key) }
    }

    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let identityObserver { NotificationCenter.default.removeObserver(identityObserver) }
    }
}

extension KVSyncCoordinator {
    private static var _shared: KVSyncCoordinator?

    public static var shared: KVSyncCoordinator? { _shared }

    /// Idempotent; no-op without the App Group suite. Call only under `#if APPSTORE`.
    @discardableResult
    public static func startShared() -> KVSyncCoordinator? {
        if let existing = _shared { return existing }
        guard let group = WidgetDataStore.groupDefaults() else { return nil }
        let coord = KVSyncCoordinator(
            defaults: group,
            kv: NSUbiquitousKeyValueStore.default,
            reload: {
                ConfigStore.shared.reloadFromDefaults()
                // The queue's synced settings live on QueueUIState, not ConfigStore.
                QueueUIState.shared.reloadFromDefaults()
            })
        _shared = coord
        if KeychainSecretStore.syncEnabled(in: group) {
            coord.start()
        } else {
            // Re-stamp Keychain secrets non-synchronizable on cold start, in case sync
            // was turned off on another device.
            KeychainSecretStore().reapplySyncAttribute(for: SecretKey.syncable)
        }
        return coord
    }
}
