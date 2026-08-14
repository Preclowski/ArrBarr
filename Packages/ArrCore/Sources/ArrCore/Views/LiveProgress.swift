import SwiftUI

/// Draws a progress value that keeps moving between fetches.
///
/// The queue is polled every 30 seconds, and Servarr's realtime `queue` push
/// carries no payload — so without this a bar would sit still for half a
/// minute and then jump, which reads as a frozen app rather than a slow one.
/// `QueueItem.interpolatedProgress(at:)` supplies the in-between positions.
///
/// The clock only runs for rows that are actually moving. That matters: a
/// queue of a hundred-plus rows is mostly paused, queued or importing, and
/// putting all of them on a one-second timer to redraw an unchanging bar is
/// exactly the cost this whole change set is trying to remove.
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
            // Phased from the measurement rather than from "now", so a row's
            // ticks line up with its own reading instead of with whenever the
            // view happened to appear.
            TimelineView(.periodic(from: measuredAt, by: 1)) { context in
                content(value(context.date))
            }
        } else {
            // No timer at all for a row that cannot move — and `value` still
            // answers with the measured position, so the two branches agree.
            content(value(.distantPast))
        }
    }
}
