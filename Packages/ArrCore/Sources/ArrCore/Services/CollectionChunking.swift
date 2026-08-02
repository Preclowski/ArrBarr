import Foundation

extension Array {
    /// Split into batches of at most `size`, keeping order.
    ///
    /// Both callers are batching work against an arr: `SpotlightIndexer` feeds
    /// CoreSpotlight in fixed-size index batches, and the queue clients chunk
    /// entity ids so a large queue can't build a query string long enough for a
    /// reverse proxy in front of the arr to reject it.
    ///
    /// Lives here rather than beside either of them — it was `fileprivate` in
    /// `SpotlightIndexer`, and the second caller would otherwise have had to
    /// copy it.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
