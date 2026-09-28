import Foundation
import OSLog
import SwiftUI

@Observable
public final class DiscoverViewModel {

    private static let log = Logger(category: "Quiz")

    // MARK: - Persistence keys

    private static let hasPickedKindKey = "ArrBarr.discoverHasPickedKind"

    // MARK: - Published state

    public var hasPickedKind: Bool {
        didSet {
            defaults.set(hasPickedKind, forKey: Self.hasPickedKindKey)
        }
    }
    public private(set) var current: DiscoverItem?
    /// Owned here, not by a surface: the seeding chat turn runs for a minute and the menu-bar
    /// panel rebuilds its views meanwhile, so a surface that must catch the moment misses it.
    public var isPresented: Bool = false

    public enum LoadPhase: Equatable, Sendable {
        case askingModel
        /// `totalIsFinal` is false while the model is still streaming picks.
        case resolving(done: Int, total: Int, totalIsFinal: Bool)
    }
    public private(set) var loadPhase: LoadPhase?
    public private(set) var loadStartedAt: Date?
    /// Never unregistered: the view model lives as long as the Quiz does.
    private var addObserver: Task<Void, Never>?
    private var openObserver: Task<Void, Never>?
    public private(set) var queue: [DiscoverItem] = []
    /// Cleared when a new session starts so "more picks" feedback carries only fresh signal.
    public private(set) var sessionMatched: [DiscoverItem] = []
    public private(set) var sessionSkipped: [DiscoverItem] = []
    /// Doesn't shrink as the user swipes; progress is `total - remaining`.
    public private(set) var sessionTotal: Int = 0
    private static let mediaSelectionKey = "ArrBarr.discoverMediaSelection"
    private let defaults: UserDefaults

    public var mediaSelection: DiscoverMediaSelection {
        didSet {
            defaults.set(mediaSelection.rawValue, forKey: Self.mediaSelectionKey)
        }
    }

    // MARK: - Internals

    private var seenKeys = Set<String>()

    /// For views deep in a chat bubble, where environment objects don't propagate reliably.
    public static let shared = DiscoverViewModel()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.mediaSelectionKey)
            .flatMap { DiscoverMediaSelection(rawValue: $0) }
        self.mediaSelection = stored ?? .movie
        self.hasPickedKind = defaults.bool(forKey: Self.hasPickedKindKey)
        // Not in the view: the deck is hidden while the add panel is up, so a view-level
        // listener would be torn down exactly when "added" arrives.
        addObserver = Task { [weak self] in
            for await message in NotificationCenter.default.messages(of: nil as AppMessageBus?, for: AppMessages.DidAddToLibrary.self) {
                self?.didAddToLibrary(foreignId: message.foreignId)
            }
        }
        openObserver = Task { [weak self] in
            for await message in NotificationCenter.default.messages(of: nil as AppMessageBus?, for: AppMessages.OpenDiscoverQuiz.self) {
                self?.open(items: message.items, append: message.append)
            }
        }
    }

    isolated deinit {
        addObserver?.cancel()
        openObserver?.cancel()
    }

    /// The chat resume card sends no picks; it only wants the deck back on screen.
    public func open(items: [DiscoverItem], append: Bool) {
        if items.isEmpty {
            // An empty round must never touch the deck: seeding it reset the session being resumed.
            Self.log.notice("quiz: reopening the deck, \(self.queue.count + (self.current == nil ? 0 : 1), privacy: .public) card(s) left")
        } else if append && hasSession {
            extend(items: items)
        } else {
            seed(items: items)
        }
        if !items.isEmpty {
            loadPhase = nil
            loadStartedAt = nil
        }
        isPresented = true
    }

    public func beginLoading() {
        if loadPhase == nil { loadStartedAt = Date() }
        loadPhase = loadPhase ?? .askingModel
        isPresented = true
    }

    public func noteResolving(done: Int, total: Int, totalIsFinal: Bool) {
        guard loadPhase != nil else { return }
        loadPhase = .resolving(done: done, total: total, totalIsFinal: totalIsFinal)
    }

    /// With no deck to show, the overlay steps aside so the chat's explanation shows.
    public func endLoading() {
        guard loadPhase != nil else { return }
        loadPhase = nil
        loadStartedAt = nil
        if !hasSession { isPresented = false }
    }

    public var hasSession: Bool {
        current != nil || !queue.isEmpty || hasSessionEngagement
    }

    /// Not `skip()`: this title was a pick, and also recording a skip would poison
    /// the signal the top-up round feeds on.
    public func didAddToLibrary(foreignId: String) {
        guard let item = current, item.result.foreignId == foreignId else { return }
        current = nil
        advanceIfNeeded()
    }

    public func seed(items: [DiscoverItem]) {
        sessionMatched.removeAll()
        sessionSkipped.removeAll()
        reset()
        sessionTotal = items.count
        for item in items {
            if seenKeys.insert(item.dedupKey).inserted {
                queue.append(item)
            }
        }
        advanceIfNeeded()
        Self.log.notice("quiz: deck seeded with \(self.queue.count + (self.current == nil ? 0 : 1), privacy: .public) of \(items.count, privacy: .public) picks")
    }

    /// Keeps the current card and feedback; new items are deduped against what was seen.
    public func extend(items: [DiscoverItem]) {
        var added = 0
        for item in items {
            if seenKeys.insert(item.dedupKey).inserted {
                queue.append(item)
                added += 1
            }
        }
        sessionTotal += added
        advanceIfNeeded()
        Self.log.notice("quiz: deck extended by \(added, privacy: .public) of \(items.count, privacy: .public) picks")
    }

    /// Read by `discover_in_quiz` before an appended round, so a top-up can't come back
    /// full of titles `extend` would silently drop.
    public var shownDedupKeys: Set<String> { seenKeys }

    /// Newest first, capped at the five anchors an appended round walks.
    public func keptTMDBIds(kind: DiscoverItemKind) -> [Int] {
        let ids = sessionMatched.reversed().filter { $0.kind == kind }.compactMap { item -> Int? in
            if kind == .show { return item.result.tmdbTVId }
            return item.result.externalId > 0 ? item.result.externalId : nil
        }
        return Array(ids.prefix(5))
    }

    /// The only action that advances the deck.
    public func skip() {
        if let item = current {
            sessionSkipped.append(item)
            // Persisted: a skip is a cooldown, or the next deck deals the same card.
            SwipeSignalStore.shared.record(key: item.dedupKey,
                                           title: item.result.title,
                                           kind: .skipped,
                                           media: item.kind == .movie ? .movie : .show)
        }
        current = nil
        advanceIfNeeded()
    }

    /// Deliberately does not advance, so a cancelled add returns to the same title.
    public func markPicked() {
        guard let item = current,
              !sessionMatched.contains(where: { $0.dedupKey == item.dedupKey }) else { return }
        sessionMatched.append(item)
        // Also clears any stale skip, so a kept title can't stay suppressed.
        SwipeSignalStore.shared.record(key: item.dedupKey,
                                       title: item.result.title,
                                       kind: .kept,
                                       media: item.kind == .movie ? .movie : .show)
    }

    /// The only permanent negative (a skip is a cooldown); still undoable.
    public func veto() {
        guard let item = current else { return }
        sessionSkipped.append(item)
        SwipeSignalStore.shared.record(key: item.dedupKey,
                                       title: item.result.title,
                                       kind: .veto,
                                       media: item.kind == .movie ? .movie : .show)
        current = nil
        advanceIfNeeded()
    }

    /// Also withdraws the persisted skip: an undone skip was a mis-swipe, not a verdict.
    public func undoSkip() {
        guard let last = sessionSkipped.popLast() else { return }
        SwipeSignalStore.shared.remove(key: last.dedupKey)
        if let onScreen = current {
            queue.insert(onScreen, at: 0)
        }
        current = last
    }

    public var canUndoSkip: Bool { !sessionSkipped.isEmpty }

    /// Without engagement "more picks like these" has no signal to feed back.
    public var hasSessionEngagement: Bool {
        !sessionMatched.isEmpty || !sessionSkipped.isEmpty
    }

    private func advanceIfNeeded() {
        if current == nil, !queue.isEmpty {
            current = queue.removeFirst()
        }
    }

    private func reset() {
        current = nil
        queue.removeAll()
        seenKeys.removeAll()
        // mediaSelection is a user preference and survives reshuffles.
    }
}
