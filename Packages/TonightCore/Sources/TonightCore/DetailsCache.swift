import Foundation

/// Title payloads already fetched this session, kept so the same title is
/// never fetched twice in a row — and, more visibly, so opening a title the
/// screen has already described does not start from an empty page.
///
/// The Home marquee asks for a slide's details to draw its facts and its
/// logo; a moment later the user clicks that slide. Without this the detail
/// page threw a spinner over the very artwork that was already on screen and
/// redrew everything a beat later. With it, the page opens with the hero
/// already written and only the parts Home never had (cast, reviews) arrive
/// afterwards.
///
/// Deliberately small and in-memory: TMDB details go stale (scores, providers)
/// and this is a session's worth of continuity, not a store.
@MainActor
final class DetailsCache {
    static let shared = DetailsCache()

    private var entries: [String: TitleDetails] = [:]
    /// Insertion order, so the oldest goes first when the cap is reached.
    private var order: [String] = []
    private let capacity = 60

    private init() {}

    subscript(id: String) -> TitleDetails? { entries[id] }

    func store(_ details: TitleDetails, for id: String) {
        if entries[id] == nil { order.append(id) }
        entries[id] = details
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }
}
