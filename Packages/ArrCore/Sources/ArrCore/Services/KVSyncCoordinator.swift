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
public final class KVSyncCoordinator {
    private let defaults: UserDefaults
    private let kv: KeyValueSyncing
    private let reload: () -> Void
    private var isApplyingRemote = false
    private let logger = Logger(category: "KVSync")
    private var observers: [NSObjectProtocol] = []

    public init(defaults: UserDefaults, kv: KeyValueSyncing, reload: @escaping () -> Void) {
        self.defaults = defaults
        self.kv = kv
        self.reload = reload
    }

    /// Begin observing inbound KVS changes and outbound UserDefaults changes,
    /// and do an initial two-way reconcile (pull remote, then push local).
    public func start() {
        let kvObs = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv as AnyObject, queue: .main
        ) { [weak self] note in
            let changed = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String])
                ?? Array(SyncedKeys.all)
            MainActor.assumeIsolated { self?.applyFromKV(keys: changed) }
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
    }

    /// Copy every allowlisted key present in UserDefaults into KVS.
    public func pushAllToKV() {
        for key in SyncedKeys.all {
            if let value = defaults.object(forKey: key) {
                kv.set(value, forKey: key)
            }
        }
    }

    /// Apply the given inbound KVS keys (allowlist-filtered) into UserDefaults,
    /// then trigger one reload. Outbound observation is suppressed meanwhile.
    public func applyFromKV(keys: [String]) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for key in keys where SyncedKeys.isSynced(key) {
            if let value = kv.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        reload()
    }

    /// Test seam: simulate the outbound observer for one key.
    public func observeDefault(_ key: String) {
        guard !isApplyingRemote, SyncedKeys.isSynced(key) else { return }
        if let value = defaults.object(forKey: key) { kv.set(value, forKey: key) }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
