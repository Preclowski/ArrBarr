import Foundation
import Observation
import OSLog

/// The queue's own view state: which sections are collapsed, and how titles
/// group. Two settings, out on their own.
///
/// They used to live on `ConfigStore`, which is an `ObservableObject` — one
/// change signal for the whole object, so collapsing a queue section
/// re-rendered every view observing it, library tiles included. Neither
/// setting means anything outside the queue, and `@Observable` tracks reads
/// per property, so moving them here scopes their invalidation to the views
/// that actually read them.
///
/// Persistence is deliberately identical to what `ConfigStore` did: the same
/// two keys, in the same resolved suite. Both are on the iCloud allow-list
/// (`SyncedKeys`), and `KVSyncCoordinator` writes inbound changes straight
/// into that suite — so the keys, the suite and `reloadFromDefaults()` are
/// load-bearing, not implementation detail.
@Observable
public final class QueueUIState {
    public static let shared = QueueUIState()
    private static let logger = Logger(category: "Queue")

    static let queueTitleGroupingKey = "ArrBarr.queueTitleGrouping"
    static let collapsedArrsKey = "ArrBarr.collapsedArrs"
    // Device-local on purpose: not in `SyncedKeys`.
    static let hiddenQueueItemsKey = "ArrBarr.hiddenQueueItems"
    static let hideHintSuppressedKey = "ArrBarr.queueHideHintSuppressed"

    public var queueTitleGrouping: QueueTitleGroupingMode = .collapsed {
        didSet {
            guard !isLoading, queueTitleGrouping != oldValue else { return }
            defaults.set(queueTitleGrouping.rawValue, forKey: Self.queueTitleGroupingKey)
        }
    }

    public var collapsedArrs: Set<String> = [] {
        didSet {
            guard !isLoading, collapsedArrs != oldValue else { return }
            defaults.set(Array(collapsedArrs), forKey: Self.collapsedArrsKey)
        }
    }

    /// `hideKey`s of rows the user hid; pruned once the download leaves the queue.
    public var hiddenQueueItems: Set<String> = [] {
        didSet {
            guard !isLoading, hiddenQueueItems != oldValue else { return }
            defaults.set(Array(hiddenQueueItems), forKey: Self.hiddenQueueItemsKey)
        }
    }

    public var hideHintSuppressed = false {
        didSet {
            guard !isLoading, hideHintSuppressed != oldValue else { return }
            defaults.set(hideHintSuppressed, forKey: Self.hideHintSuppressedKey)
        }
    }

    /// "Show hidden" from the menu; session-only.
    public var showHiddenQueueItems = false
    /// ⌥ held while the panel is key (macOS).
    public var optionKeyHeld = false

    public var revealsHiddenQueueItems: Bool { showHiddenQueueItems || optionKeyHeld }

    /// True while `load(from:)` assigns — the setters above persist, and a
    /// reload writing the values it just read back is at best pointless work
    /// and at worst (through `UserDefaults.didChangeNotification`) an iCloud
    /// push echoing a change that came from iCloud. Starts `true` because the
    /// first load happens inside `init`.
    @ObservationIgnored private var isLoading = true
    @ObservationIgnored private var defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? ConfigStore.resolveDefaults()
        load(from: self.defaults)
    }

    /// Follow `ConfigStore` onto another suite (the demo toggle). Called from
    /// `ConfigStore.useStore` so the two can't end up reading different
    /// profiles.
    func use(_ target: UserDefaults) {
        guard target !== defaults else { return }
        defaults = target
        load(from: target)
    }

    /// Re-read after `KVSyncCoordinator` applied inbound iCloud values.
    public func reloadFromDefaults() {
        load(from: defaults)
    }

    private func load(from source: UserDefaults) {
        isLoading = true
        defer { isLoading = false }
        queueTitleGrouping = QueueTitleGroupingMode(
            rawValue: source.string(forKey: Self.queueTitleGroupingKey) ?? ""
        ) ?? .collapsed
        collapsedArrs = Set(source.stringArray(forKey: Self.collapsedArrsKey) ?? [])
        hiddenQueueItems = Set(source.stringArray(forKey: Self.hiddenQueueItemsKey) ?? [])
        hideHintSuppressed = source.bool(forKey: Self.hideHintSuppressedKey)
    }

    // MARK: - Collapse

    public func toggleCollapsed(_ key: String) {
        if collapsedArrs.contains(key) {
            collapsedArrs.remove(key)
        } else {
            collapsedArrs.insert(key)
        }
    }

    public func isCollapsed(_ key: String) -> Bool {
        collapsedArrs.contains(key)
    }

    public func toggleCollapsed(_ arr: QueueItem.Source) { toggleCollapsed(arr.rawValue) }
    public func isCollapsed(_ arr: QueueItem.Source) -> Bool { isCollapsed(arr.rawValue) }

    // MARK: - Hidden rows

    public func isHidden(_ item: QueueItem) -> Bool {
        guard !hiddenQueueItems.isEmpty else { return false }
        return item.hideMatchKeys.contains { hiddenQueueItems.contains($0) }
    }

    public func areHidden(_ items: [QueueItem]) -> Bool {
        !items.isEmpty && items.allSatisfy(isHidden)
    }

    public func hide(_ items: [QueueItem]) {
        hiddenQueueItems.formUnion(items.map(\.hideKey))
    }

    public func unhide(_ items: [QueueItem]) {
        hiddenQueueItems.subtract(items.flatMap(\.hideMatchKeys))
    }

    /// Drop keys of `source` that no longer match anything in a fresh, successful fetch.
    func pruneHidden(source: QueueItem.Source, present: [QueueItem]) {
        let prefix = "\(source.rawValue)|"
        guard hiddenQueueItems.contains(where: { $0.hasPrefix(prefix) }) else { return }
        let live = Set(present.flatMap(\.hideMatchKeys))
        let kept = hiddenQueueItems.filter { !$0.hasPrefix(prefix) || live.contains($0) }
        guard kept != hiddenQueueItems else { return }
        Self.logger.notice("dropped \(self.hiddenQueueItems.count - kept.count, privacy: .public) hidden \(source.rawValue, privacy: .public) row(s) no longer in a queue of \(present.count, privacy: .public)")
        hiddenQueueItems = kept
    }
}
