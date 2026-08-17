import Foundation

/// Order-preserving concurrent map with a concurrency cap.
///
/// The quiz and suggestion flows resolve dozens of model picks through arr
/// lookups; done one-by-one that is 60 sequential LAN round-trips before the
/// first card can show. Done all-at-once it dogpiles a Radarr that is also
/// serving its own UI. A small window keeps the wall-clock at
/// ~(count / width) round-trips without either extreme.
enum ParallelResolve {

    /// Runs `transform` over `items` with at most `width` in flight, returning
    /// results in the input order. Failures are the transform's business —
    /// return nil (and `compactMap` after) rather than throwing, matching how
    /// the pick-resolution loops already swallow individual lookup misses.
    static func orderedMap<In: Sendable, Out: Sendable>(
        _ items: [In],
        width: Int,
        _ transform: @escaping @Sendable (In) async -> Out
    ) async -> [Out] {
        guard !items.isEmpty else { return [] }
        let cap = max(1, width)
        var results = [Out?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Out).self) { group in
            var next = 0
            func enqueue() {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask { (index, await transform(item)) }
            }
            for _ in 0..<min(cap, items.count) { enqueue() }
            for await (index, value) in group {
                results[index] = value
                enqueue()
            }
        }
        // Every slot was filled by the loop above; the compactMap is shape
        // conversion, not filtering.
        return results.compactMap { $0 }
    }
}
