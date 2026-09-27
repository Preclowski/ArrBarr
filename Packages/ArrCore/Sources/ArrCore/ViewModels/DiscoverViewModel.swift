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
    /// The deck wants to be on screen. Owned HERE rather than by each surface:
    /// a quiz is seeded from a chat turn that runs for a minute, and the
    /// surfaces that could catch the opening message come and go inside that
    /// minute (the menu-bar panel tears its view tree down and rebuilds it
    /// constantly, and it is gone entirely while the popover is shut). A
    /// surface that reads this flag renders the right thing whenever it
    /// happens to be built; one that has to *catch* the moment misses it.
    public var isPresented: Bool = false

    public enum LoadPhase: Equatable, Sendable {
        case askingModel
        /// `totalIsFinal` is false while the model is still streaming picks.
        case resolving(done: Int, total: Int, totalIsFinal: Bool)
    }
    /// Non-nil from the moment a fresh deck is requested until its first card
    /// lands (or the attempt ends without one).
    public private(set) var loadPhase: LoadPhase?
    public private(set) var loadStartedAt: Date?
    /// Held for the view model's lifetime — the observers must outlive every
    /// deck the user opens, and the view model itself lives as long as the
    /// Quiz does, so there is nothing to unregister early.
    private var addObserver: Task<Void, Never>?
    private var openObserver: Task<Void, Never>?
    public private(set) var queue: [DiscoverItem] = []
    /// Cards the user swiped right (chose to add) in the current session
    /// (since the last `seed(items:)`). Cleared when a new session
    /// starts so the "more picks" feedback only carries fresh signal; also
    /// drives `QuizResumeCard`'s count.
    public private(set) var sessionMatched: [DiscoverItem] = []
    /// Cards the user skipped (>>) in the current session.
    public private(set) var sessionSkipped: [DiscoverItem] = []
    /// Total number of picks the agent seeded for the current session.
    /// Set by `seed(items:)` and used by the View to render the
    /// "N / total" progress chip. Doesn't shrink as the user swipes —
    /// progress is derived as `total - (queue.count + (current == nil ? 0 : 1))`.
    public private(set) var sessionTotal: Int = 0
    /// Media kind the user selected in the picker segmented control.
    /// Persisted to UserDefaults so the choice survives app restarts.
    private static let mediaSelectionKey = "ArrBarr.discoverMediaSelection"
    private let defaults: UserDefaults

    public var mediaSelection: DiscoverMediaSelection {
        didSet {
            defaults.set(mediaSelection.rawValue, forKey: Self.mediaSelectionKey)
        }
    }

    // MARK: - Internals

    private var seenKeys = Set<String>()

    /// Process-wide shared instance. Used by views that can't easily
    /// reach the popover-owned `@StateObject` (e.g. `QuizResumeCard`
    /// rendered deep inside a chat message bubble where environment
    /// objects don't always propagate reliably). PopoverContentView
    /// uses the same `.shared` instance so the state stays unified.
    public static let shared = DiscoverViewModel()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.mediaSelectionKey)
            .flatMap { DiscoverMediaSelection(rawValue: $0) }
        self.mediaSelection = stored ?? .movie
        self.hasPickedKind = defaults.bool(forKey: Self.hasPickedKindKey)
        // Observed HERE rather than in the view: the deck is hidden while the
        // add panel is up, so a view-level listener would be torn down exactly
        // when the "added" signal arrives.
        addObserver = Task { [weak self] in
            for await message in NotificationCenter.default.messages(of: nil as AppMessageBus?, for: AppMessages.DidAddToLibrary.self) {
                self?.didAddToLibrary(foreignId: message.foreignId)
            }
        }
        // Same reasoning, one level up: the deck itself is seeded here, not by
        // whichever surface happened to be mounted when the tool finished.
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

    /// A quiz round landed: from `discover_in_quiz`, from the demo provider, or
    /// from the resume card in chat (which carries no picks — it only wants the
    /// deck back on screen).
    public func open(items: [DiscoverItem], append: Bool) {
        if items.isEmpty {
            // Never let an empty round touch the deck. This is the resume
            // card's message, and seeding it reset the session the user was
            // asking to return to.
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

    /// A fresh deck is on its way: put the overlay up now rather than when
    /// the last lookup returns.
    public func beginLoading() {
        if loadPhase == nil { loadStartedAt = Date() }
        loadPhase = loadPhase ?? .askingModel
        isPresented = true
    }

    public func noteResolving(done: Int, total: Int, totalIsFinal: Bool) {
        guard loadPhase != nil else { return }
        loadPhase = .resolving(done: done, total: total, totalIsFinal: totalIsFinal)
    }

    /// The attempt is over. With no deck to show, the overlay steps aside so
    /// the chat's explanation is what the user sees.
    public func endLoading() {
        guard loadPhase != nil else { return }
        loadPhase = nil
        loadStartedAt = nil
        if !hasSession { isPresented = false }
    }

    /// Whether there is a session to return to or extend — cards still in hand,
    /// or verdicts already given on this round.
    public var hasSession: Bool {
        current != nil || !queue.isEmpty || hasSessionEngagement
    }

    /// The user finished adding the card they were on — drop it and move to the
    /// next. Not `skip()`: this title was a *pick* (already recorded by
    /// `markPicked`), and recording it as skipped too would poison the signal
    /// the top-up round feeds on.
    public func didAddToLibrary(foreignId: String) {
        guard let item = current, item.result.foreignId == foreignId else { return }
        current = nil
        advanceIfNeeded()
    }

    /// Replace the deck with a pre-resolved set of picks (typically from
    /// a chat tool that has the titles in hand). Skips the fetch pipeline
    /// entirely — the seeded deck IS the session. When the user wants
    /// more, they ask explicitly (Q2 chat round-trip).
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

    /// Append more picks to the active session without resetting state.
    /// Used by the "more picks" flow — the user keeps their current card,
    /// matched/skipped feedback survives, and the new items merge into
    /// the deck (deduped against what they've already seen).
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

    /// Every card this session has already put in front of the user — still
    /// in the deck, current, or long since swiped. The `discover_in_quiz`
    /// tool reads this before an appended round lands so a top-up can't come
    /// back full of titles `extend` would silently drop (which reads to the
    /// user as "no more cards" while a manual retry still finds picks).
    public var shownDedupKeys: Set<String> { seenKeys }

    /// TMDB ids of this session's kept titles, newest first, capped at the
    /// five anchors an appended round walks.
    public func keptTMDBIds(kind: DiscoverItemKind) -> [Int] {
        let ids = sessionMatched.reversed().filter { $0.kind == kind }.compactMap { item -> Int? in
            if kind == .show { return item.result.tmdbTVId }
            return item.result.externalId > 0 ? item.result.externalId : nil
        }
        return Array(ids.prefix(5))
    }

    /// Skip the current card (>>) — records it as skipped for the
    /// engagement signal and advances to the next. This is the only action
    /// that advances the deck.
    public func skip() {
        if let item = current {
            sessionSkipped.append(item)
            // Persist the verdict: a skip is a cooldown, not a session-local
            // fact — without this the very next deck deals the same card.
            SwipeSignalStore.shared.record(key: item.dedupKey,
                                           title: item.result.title,
                                           kind: .skipped,
                                           media: item.kind == .movie ? .movie : .show)
        }
        current = nil
        advanceIfNeeded()
    }

    /// Record that the user chose to add the current card (a "pick", drives
    /// `QuizResumeCard`'s count). Deliberately does NOT advance — opening the
    /// add card leaves the user on the same title so a cancelled add returns
    /// to it. Deduped so opening the add card twice on one title counts once.
    public func markPicked() {
        guard let item = current,
              !sessionMatched.contains(where: { $0.dedupKey == item.dedupKey }) else { return }
        sessionMatched.append(item)
        // Positive signal outlives the session — and clears any stale skip,
        // so a kept title can't stay suppressed by last month's mood.
        SwipeSignalStore.shared.record(key: item.dedupKey,
                                       title: item.result.title,
                                       kind: .kept,
                                       media: item.kind == .movie ? .movie : .show)
    }

    /// Explicit "not interested": the only PERMANENT negative — a plain skip
    /// is just a cooldown. Still lands on the undo stack, so a slip of the
    /// finger is reversible (undo withdraws the veto signal too).
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

    /// Undo the most recent skip: the last skipped card becomes current again
    /// and the one on screen slides back into the queue's front. Clicking
    /// repeatedly walks further back through this session's skips. Also
    /// withdraws the persisted skip signal — an undone skip was a mis-swipe,
    /// not a verdict, and must not cool the title down for two weeks.
    public func undoSkip() {
        guard let last = sessionSkipped.popLast() else { return }
        SwipeSignalStore.shared.remove(key: last.dedupKey)
        if let onScreen = current {
            queue.insert(onScreen, at: 0)
        }
        current = last
    }

    /// Whether there is a skip to undo — drives the deck's back button.
    public var canUndoSkip: Bool { !sessionSkipped.isEmpty }

    /// True when the user has actually engaged with the deck this session.
    /// Used by the overlay to decide whether to surface "more picks like
    /// these" — without engagement the button has no signal to feed back.
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
        // Note: mediaSelection is intentionally NOT reset here — it's a
        // user-level preference that persists across reshuffles.
    }
}
