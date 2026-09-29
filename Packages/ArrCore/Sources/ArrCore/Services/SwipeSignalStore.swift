import Foundation

/// `key` is `DiscoverItem.dedupKey`, so a title collides across sources and sessions.
nonisolated public struct SwipeSignal: Codable, Sendable, Equatable {
    nonisolated public enum Kind: String, Codable, Sendable {
        case kept
        /// A cooldown, never a verdict: it expires, and only repetition extends it.
        case skipped
        /// The only permanent state, because the user said it explicitly.
        case veto
    }
    /// Optional: entries persisted before the field existed decode without it.
    nonisolated public enum Media: String, Codable, Sendable {
        case movie, show, music
    }
    public var key: String
    /// Display label for the Quiz settings pane; never matched on.
    public var title: String
    public var kind: Kind
    public var date: Date
    public var count: Int
    public var media: Media?
}

/// Persistent quiz-swipe memory. A skip suppresses a title for 14 days, a repeat skip for 90;
/// only a veto is forever. Kept titles never suppress anything.
public final class SwipeSignalStore {

    public static let shared = SwipeSignalStore()

    static let storageKey = "ArrBarr.swipeSignals"
    public static let skipCooldown: TimeInterval = 14 * 24 * 3600
    public static let repeatSkipCooldown: TimeInterval = 90 * 24 * 3600
    /// Oldest non-veto entries fall off first — that FIFO is the long-tail forgetting.
    static let cap = 500

    private let defaults: UserDefaults
    private var signals: [SwipeSignal]

    public init(defaults: UserDefaults = DemoMode.profileDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SwipeSignal].self, from: data) {
            signals = decoded
        } else {
            signals = []
        }
    }

    // MARK: - Recording

    public func record(key: String, title: String, kind: SwipeSignal.Kind,
                       media: SwipeSignal.Media? = nil, now: Date = Date()) {
        guard !key.isEmpty else { return }
        // A series key is its TVDB id, a movie key its TMDB id: the same number can name both.
        if let idx = signals.firstIndex(where: { $0.key == key && Self.sameMedia($0.media, media) }) {
            var signal = signals[idx]
            switch (signal.kind, kind) {
            case (.veto, .skipped):
                return
            case (.skipped, .skipped):
                signal.count += 1
                signal.date = now
            default:
                // Latest decision wins: a kept title stays unsuppressed, a skip overwrites a stale kept.
                signal.kind = kind
                signal.date = now
                signal.count = (kind == .skipped) ? signal.count + 1 : signal.count
            }
            signal.title = title
            if let media { signal.media = media }
            signals.remove(at: idx)
            signals.append(signal)
        } else {
            signals.append(SwipeSignal(key: key, title: title, kind: kind,
                                       date: now, count: kind == .skipped ? 1 : 0,
                                       media: media))
        }
        enforceCap()
        persist()
    }

    // MARK: - Reads

    /// `media` keeps a skipped show from hiding the movie whose TMDB id equals its TVDB id. Untyped legacy entries count for every type.
    public func suppressedKeys(media: SwipeSignal.Media? = nil, now: Date = Date()) -> Set<String> {
        Set(signals.compactMap { signal in
            isSuppressed(signal, now: now) && Self.sameMedia(signal.media, media) ? signal.key : nil
        })
    }

    private static func sameMedia(_ a: SwipeSignal.Media?, _ b: SwipeSignal.Media?) -> Bool {
        guard let a, let b else { return true }
        return a == b
    }

    /// Newest first.
    public var all: [SwipeSignal] { signals.reversed() }

    // MARK: - Management

    /// Vetoes and kept signals survive.
    public func resetSkips() {
        signals.removeAll { $0.kind == .skipped }
        persist()
    }

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
        // Never a veto, unless everything is a veto — then the oldest go rather than growing without bound.
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
