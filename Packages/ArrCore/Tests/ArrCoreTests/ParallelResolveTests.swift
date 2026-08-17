import Foundation
import Testing
@testable import ArrCore

@Suite("ParallelResolve")
struct ParallelResolveTests {

    @Test("preserves input order regardless of completion order")
    func preservesOrder() async {
        let input = Array(0..<40)
        let out = await ParallelResolve.orderedMap(input, width: 8) { n -> Int in
            // Later items finish sooner — reversed sleep scrambles completion order.
            try? await Task.sleep(nanoseconds: UInt64((40 - n)) * 200_000)
            return n * 2
        }
        #expect(out == input.map { $0 * 2 })
    }

    @Test("never exceeds the concurrency cap")
    func respectsWidth() async {
        actor Gauge {
            var current = 0
            var peak = 0
            func enter() { current += 1; peak = max(peak, current) }
            func leave() { current -= 1 }
        }
        let gauge = Gauge()
        _ = await ParallelResolve.orderedMap(Array(0..<30), width: 4) { _ -> Int in
            await gauge.enter()
            try? await Task.sleep(nanoseconds: 2_000_000)
            await gauge.leave()
            return 0
        }
        #expect(await gauge.peak <= 4)
    }

    @Test("empty input returns empty without spawning work")
    func emptyInput() async {
        let out = await ParallelResolve.orderedMap([Int](), width: 8) { $0 }
        #expect(out.isEmpty)
    }
}
