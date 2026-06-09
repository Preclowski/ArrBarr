import Foundation
import os

/// Abstraction over `NSUbiquitousKeyValueStore` so the coordinator is testable
/// without a real iCloud account.
public protocol KeyValueSyncing: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueSyncing {}

/// Mirrors the `SyncedKeys` allowlist between UserDefaults (local source of
/// truth) and iCloud KVS. Compiled in all builds for testability; only started
/// (`start()`) by the app under `#if APPSTORE`.
@MainActor
public final class KVSyncCoordinator: ObservableObject {
    private let defaults: UserDefaults
    private let kv: KeyValueSyncing
    private let reload: () -> Void
    private var isApplyingRemote = false
    private let logger = Logger(category: "KVSync")
    private var observers: [NSObjectProtocol] = []

    /// Timestamp of the last successful push or pull. `nil` until first sync.
    @Published public private(set) var lastSyncDate: Date?
    /// Human-readable description of the last sync failure, or `nil` if healthy.
    @Published public private(set) var lastError: String?
    /// Whether the coordinator is currently observing and mirroring changes.
    @Published public private(set) var isRunning: Bool = false

    /// Whether this device is signed into iCloud (Keychain/KVS can replicate).
    /// Stored + `@Published` so the settings UI refreshes when it changes;
    /// recomputed on `start()`/`stop()`.
    @Published public private(set) var accountAvailable: Bool
        = FileManager.default.ubiquityIdentityToken != nil

    public init(defaults: UserDefaults, kv: KeyValueSyncing, reload: @escaping () -> Void) {
        self.defaults = defaults
        self.kv = kv
        self.reload = reload
    }

    /// Begin observing inbound KVS changes and outbound UserDefaults changes,
    /// and do an initial two-way reconcile (pull remote, then push local).
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
                self.lastError = (reason == NSUbiquitousKeyValueStoreQuotaViolationChange)
                    ? String(localized: "iCloud storage is full \u{2014} some settings couldn\u{2019}t sync.", bundle: .module)
                    : nil
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
    }

    /// Stop observing and mirroring. Existing KVS/Keychain data is left intact.
    public func stop() {
        refreshAccountAvailability()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        isRunning = false
    }

    private func refreshAccountAvailability() {
        accountAvailable = FileManager.default.ubiquityIdentityToken != nil
    }

    /// Idempotently start or stop syncing to match the user's toggle.
    public func setEnabled(_ enabled: Bool) {
        if enabled {
            guard !isRunning else { return }
            start()
        } else {
            guard isRunning else { return }
            stop()
        }
    }

    /// Copy every allowlisted key present in UserDefaults into KVS.
    public func pushAllToKV() {
        for key in SyncedKeys.all {
            if let value = defaults.object(forKey: key) {
                kv.set(value, forKey: key)
            }
        }
        if accountAvailable { lastSyncDate = Date() }
    }

    /// Apply the given inbound KVS keys (allowlist-filtered) into UserDefaults,
    /// then trigger one reload. Outbound observation is suppressed meanwhile.
    public func applyFromKV(keys: [String]) {
        isApplyingRemote = true
        for key in keys where SyncedKeys.isSynced(key) {
            if let value = kv.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        reload()
        // Reset on a later main-queue tick so the asynchronous outbound
        // `didChangeNotification` observer (queue: .main, enqueued by the
        // `defaults.set` calls above) still sees `isApplyingRemote == true`
        // and skips the redundant re-push of the value we just applied.
        DispatchQueue.main.async { [weak self] in self?.isApplyingRemote = false }
    }

    /// Test seam: simulate the outbound observer for one key.
    public func observeDefault(_ key: String) {
        guard !isApplyingRemote, SyncedKeys.isSynced(key) else { return }
        if let value = defaults.object(forKey: key) { kv.set(value, forKey: key) }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}

@MainActor
extension KVSyncCoordinator {
    private static var _shared: KVSyncCoordinator?

    /// The process-wide coordinator, if one has been created. Read-only access
    /// for UI (status display) and for `ConfigStore`'s toggle sink.
    public static var shared: KVSyncCoordinator? { _shared }

    /// Create, retain, and (if iCloud sync is enabled) start the process-wide
    /// coordinator bound to the real App Group suite and the live iCloud KVS.
    /// Idempotent. No-op if the group suite is unavailable. Call only under
    /// `#if APPSTORE`.
    @discardableResult
    public static func startShared() -> KVSyncCoordinator? {
        if let existing = _shared { return existing }
        guard let group = WidgetDataStore.groupDefaults() else { return nil }
        let coord = KVSyncCoordinator(
            defaults: group,
            kv: NSUbiquitousKeyValueStore.default,
            reload: { ConfigStore.shared.reloadFromDefaults() })
        _shared = coord
        if KeychainSecretStore.syncEnabled(in: group) {
            coord.start()
        } else {
            // Sync is off: re-stamp existing Keychain secrets as
            // non-synchronizable at launch so the "off = don't replicate"
            // guarantee holds even if the flag was turned off on another device
            // (the in-app toggle already does this; this covers cold starts).
            KeychainSecretStore().reapplySyncAttribute(for: SecretKey.syncable)
        }
        return coord
    }
}
