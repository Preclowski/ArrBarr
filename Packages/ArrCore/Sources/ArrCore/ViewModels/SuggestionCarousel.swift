import Foundation

/// The rotating shortlist of chat suggestions under the welcome card.
///
/// Lives outside the view because it is the only part of that surface with
/// rules worth stating — which slot changes next, what may replace it, what
/// happens when the pool is smaller than the window — and a view that renders
/// nothing under `swift test` is no place to keep them.
@Observable
public final class SuggestionCarousel {
    /// Every suggestion the welcome screen can offer. Deliberately longer than
    /// the window: a fixed handful made the chat look like it knew a handful of
    /// tricks. Each one is a question the tools can actually answer.
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

    /// The keys on offer, longest window first — the surface renders a prefix
    /// of this and tells us how much of it it could actually place.
    public private(set) var visible: [String]

    private let pool: [String]
    /// The slot the next `advance` will replace. Walking down the list rather
    /// than picking at random is what makes the movement read as one thing
    /// travelling, instead of rows blinking at each other.
    private var cursor = 0

    public init(pool: [String] = SuggestionCarousel.pool, window: Int, shuffled: Bool = true) {
        self.pool = pool
        let ordered = shuffled ? pool.shuffled() : pool
        self.visible = Array(ordered.prefix(max(0, window)))
    }

    /// Replaces one slot with a suggestion that isn't on screen, and moves the
    /// cursor on. `displayed` is how many rows the layout actually placed (the
    /// panel is short, the keyboard is up): a slot the user can't see is not a
    /// change, it's a beat where nothing happens.
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
