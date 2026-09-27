import Foundation

/// Rotating chat suggestions under the welcome card. Outside the view so its rules are testable:
/// a view renders nothing under `swift test`.
@Observable
public final class SuggestionCarousel {
    /// Longer than the window on purpose; each is a question the tools can actually answer.
    nonisolated public static let pool: [String] = [
        "chat.empty.suggest.upcoming",
        "chat.empty.suggest.queue",
        "chat.empty.suggest.tasteMrRobot",
        "chat.empty.suggest.personSwinton",
        "chat.empty.suggest.shortTonight",
        "chat.empty.suggest.familyNight",
        "chat.empty.suggest.bingeWeekend",
        "chat.empty.suggest.bestUnwatched",
        "chat.empty.suggest.classic",
        "chat.empty.suggest.surpriseMe",
        "chat.empty.suggest.missingEpisodes",
        "chat.empty.suggest.stuckQueue",
        "chat.empty.suggest.diskSpace",
        "chat.empty.suggest.likeBladeRunner",
        "chat.empty.suggest.thisWeek",
        "chat.empty.suggest.rainyEvening",
    ]

    /// The surface renders a prefix and reports how much of it fit.
    public private(set) var visible: [String]

    private let pool: [String]
    /// Walking the list rather than picking at random makes the movement read as one thing travelling.
    private var cursor = 0

    public init(pool: [String] = SuggestionCarousel.pool, window: Int, shuffled: Bool = true) {
        self.pool = pool
        let ordered = shuffled ? pool.shuffled() : pool
        self.visible = Array(ordered.prefix(max(0, window)))
    }

    /// `displayed` is how many rows actually fit: replacing a slot the user can't see changes nothing.
    public func advance(within displayed: Int) {
        let window = min(displayed, visible.count)
        guard window > 0 else { return }
        let slot = cursor % window
        cursor = (slot + 1) % window
        let onScreen = Set(visible)
        guard let incoming = pool.filter({ !onScreen.contains($0) }).randomElement() else { return }
        visible[slot] = incoming
    }
}
