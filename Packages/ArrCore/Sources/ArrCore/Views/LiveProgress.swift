import SwiftUI

/// Keeps a bar moving between fetches (Servarr's `queue` push carries no payload).
/// The one-second clock runs only for rows that are actually moving.
struct LiveProgress<Content: View>: View {
    private let isLive: Bool
    private let measuredAt: Date
    private let value: (Date) -> Double
    private let content: (Double) -> Content

    init(item: QueueItem, @ViewBuilder content: @escaping (Double) -> Content) {
        let measuredAt = QueueViewModel.shared.progressMeasuredAt(for: item.source)
        self.isLive = item.isInterpolatingProgress
        self.measuredAt = measuredAt
        self.value = { item.interpolatedProgress(at: $0, measuredAt: measuredAt) }
        self.content = content
    }

    init(group: QueueTitleGroup, @ViewBuilder content: @escaping (Double) -> Content) {
        // A group is one title from one arr, so its rows share a fetch.
        let measuredAt = group.allItems.first
            .map { QueueViewModel.shared.progressMeasuredAt(for: $0.source) } ?? .distantPast
        self.isLive = group.isInterpolatingProgress
        self.measuredAt = measuredAt
        self.value = { group.aggregateProgress(at: $0, measuredAt: measuredAt) }
        self.content = content
    }

    var body: some View {
        if isLive {
            // Phased from the measurement so ticks line up with the row's own reading.
            TimelineView(.periodic(from: measuredAt, by: 1)) { context in
                content(value(context.date))
            }
        } else {
            content(value(.distantPast))
        }
    }
}
