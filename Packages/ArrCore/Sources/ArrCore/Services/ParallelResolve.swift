import Foundation

/// Order-preserving concurrent map with a cap: sequential lookups delay the first card by dozens of LAN
/// round trips, all at once dogpiles a Radarr serving its own UI.
enum ParallelResolve {

    /// Failures are the transform's business: return nil rather than throw.
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
