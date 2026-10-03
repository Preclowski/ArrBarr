import Foundation
import Observation

/// Calendar days before now, fetched backwards a fortnight at a time as the Upcoming list is scrolled up.
@Observable
final class PastCalendarFeed {
    typealias Fetch = @MainActor (_ start: Date, _ end: Date) async -> [UpcomingItem]

    /// Oldest first, like the upcoming list they sit above.
    private(set) var items: [UpcomingItem] = []
    private(set) var isLoading = false

    @ObservationIgnored private var earliest: Date?
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let stepDays: Int
    @ObservationIgnored private let maxSteps: Int

    init(stepDays: Int = 14, maxSteps: Int = 6, fetch: @escaping Fetch) {
        self.stepDays = stepDays
        self.maxSteps = maxSteps
        self.fetch = fetch
    }

    /// Walks back past empty fortnights, up to `maxSteps`, so one scroll always brings rows if any exist.
    /// Returns whether it added any.
    @discardableResult
    func loadEarlier(now: Date = Date()) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }
        let calendar = Calendar.current
        var end = earliest ?? now
        var found: [UpcomingItem] = []
        for _ in 0..<maxSteps where found.isEmpty {
            let start = calendar.date(byAdding: .day, value: -stepDays, to: calendar.startOfDay(for: end))!
            // Radarr dates a movie by its digital release even when the cinema date put it in the window.
            found = await fetch(start, end).filter { $0.airDate >= start && $0.airDate < end }
            end = start
        }
        earliest = end
        let known = Set(items.map(\.id))
        let fresh = found.filter { !known.contains($0.id) }.sorted { $0.airDate < $1.airDate }
        items = fresh + items
        return !fresh.isEmpty
    }
}
