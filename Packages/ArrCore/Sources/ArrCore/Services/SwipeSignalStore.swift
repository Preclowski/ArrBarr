import Foundation

/// One remembered quiz verdict. `key` is `DiscoverItem.dedupKey`, so the same
/// title collides across sources (curated, anchors, library) and sessions.
public struct SwipeSignal: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Right swipe — positive taste signal (future anchor / profile food).
        case kept
        /// Left swipe — "not now". A cooldown, never a verdict: it expires,
        /// and only repetition extends it.
        case skipped
        /// Explicit "not interested" — the only permanent state, because it is
        /// the only one the user said out loud.
        case veto
    }
    public var key: String
    /// Human-readable label for the future signals UI; never matched on.
    public var title: String
    public var kind: Kind
    /// When the signal last fired (a re-skip refreshes it).
    public var date: Date
    /// How many times this title was skipped, across sessions.
    public var count: Int
}

/// Persistent quiz-swipe memory. Before this, every `seed()` wiped the
/// session's verdicts, so a title skipped last night led the very next deck.
///
/// The forgetting model is deliberate UX, not bookkeeping (2026-08-17 design
/// discussion): a skip suppresses the title for 14 days; a repeat skip means
/// it wasn't a mood, so it stretches to 90; only an explicit veto is forever.
/// Kept titles are recorded as positive signal and never suppress anything.
@MainActor
public final class SwipeSignalStore {

    public static let shared = SwipeSignalStore()

    static let storageKey = "ArrBarr.swipeSignals"
    /// First skip: two weeks out of the decks — long enough that the next few
    /// sessions aren't déjà vu, short enough that "not tonight" is not a life
    /// sentence.
    public static let skipCooldown: TimeInterval = 14 * 24 * 3600
    /// Skipped twice or more across different sessions: taste, not mood.
    public static let repeatSkipCooldown: TimeInterval = 90 * 24 * 3600
    /// Cap on remembered signals. Oldest non-veto entries fall off first —
    /// FIFO expiry IS the long-tail forgetting model.
    static let cap = 500

    private let defaults: UserDefaults
    private var signals: [SwipeSignal]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SwipeSignal].self, from: data) {
            signals = decoded
        } else {
            signals = []
        }
    }

    // MARK: - Recording

    public func record(key: String, title: String, kind: SwipeSignal.Kind, now: Date = Date()) {
        guard !key.isEmpty else { return }
        if let idx = signals.firstIndex(where: { $0.key == key }) {
            var signal = signals[idx]
            switch (signal.kind, kind) {
            case (.veto, .skipped):
                // A veto outranks an ambient skip; nothing to update.
                return
            case (.skipped, .skipped):
                signal.count += 1
                signal.date = now
            default:
                // kept/veto overwrite whatever was there (a kept title was
                // wrongly suppressed if it stayed skipped), and skipped
                // overwrites a stale kept — latest decision wins.
                signal.kind = kind
                signal.date = now
                signal.count = (kind == .skipped) ? signal.count + 1 : signal.count
            }
            signal.title = title
            signals.remove(at: idx)
            signals.append(signal)   // newest last → cap drops oldest first
        } else {
            signals.append(SwipeSignal(key: key, title: title, kind: kind,
                                       date: now, count: kind == .skipped ? 1 : 0))
        }
        enforceCap()
        persist()
    }

    // MARK: - Reads

    /// Keys the decks must not deal right now: active skip cooldowns + vetoes.
    public func suppressedKeys(now: Date = Date()) -> Set<String> {
        Set(signals.compactMap { signal in
            isSuppressed(signal, now: now) ? signal.key : nil
        })
    }

    public func isSuppressed(_ key: String, now: Date = Date()) -> Bool {
        guard let signal = signals.first(where: { $0.key == key }) else { return false }
        return isSuppressed(signal, now: now)
    }

    /// Everything remembered, newest first — the future signals pane reads this.
    public var all: [SwipeSignal] { signals.reversed() }

    // MARK: - Management

    /// Clears skip cooldowns (the "Reset skips" affordance). Vetoes and kept
    /// signals survive — the user said those out loud.
    public func resetSkips() {
        signals.removeAll { $0.kind == .skipped }
        persist()
    }

    /// Drops one signal entirely (row-level "Undo" / "Restore").
    public func remove(key: String) {
        signals.removeAll { $0.key == key }
        persist()
    }

    // MARK: - Internals

    private func isSuppressed(_ signal: SwipeSignal, now: Date) -> Bool {
        switch signal.kind {
        case .kept: return false
        case .veto: return true
        case .skipped:
            let cooldown = signal.count >= 2 ? Self.repeatSkipCooldown : Self.skipCooldown
            return now.timeIntervalSince(signal.date) < cooldown
        }
    }

    private func enforceCap() {
        guard signals.count > Self.cap else { return }
        // Evict oldest-first but never a veto; if somehow all vetoes, oldest
        // vetoes go too rather than growing without bound.
        var overflow = signals.count - Self.cap
        var kept: [SwipeSignal] = []
        for signal in signals {
            if overflow > 0 && signal.kind != .veto {
                overflow -= 1
                continue
            }
            kept.append(signal)
        }
        if overflow > 0 { kept.removeFirst(min(overflow, kept.count)) }
        signals = kept
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(signals) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
