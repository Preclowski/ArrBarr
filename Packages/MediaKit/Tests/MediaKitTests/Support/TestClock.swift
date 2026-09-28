import Foundation
import os
@testable import MediaKit

/// Deterministic time for tests: `sleep` suspends until `advance(by:)` passes the wake time.
final class TestClock: MediaClock, Sendable {
    private struct Sleeper { let wakeAt: Date; let continuation: CheckedContinuation<Void, any Error> }
    private struct State { var now: Date; var sleepers: [Sleeper] = []; var autoAdvance = false }
    private let state: OSAllocatedUnfairLock<State>

    /// When set, every `sleep` jumps the clock forward instead of waiting for `advance(by:)`.
    var autoAdvance: Bool {
        get { state.withLock { $0.autoAdvance } }
        set { state.withLock { $0.autoAdvance = newValue } }
    }

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        state = OSAllocatedUnfairLock(initialState: State(now: start))
    }

    var now: Date { state.withLock { $0.now } }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let wakeAt = now.addingTimeInterval(duration.seconds)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let fireNow = state.withLock { s -> Bool in
                if s.autoAdvance { s.now = max(s.now, wakeAt); return true }
                if wakeAt <= s.now { return true }
                s.sleepers.append(Sleeper(wakeAt: wakeAt, continuation: continuation))
                return false
            }
            if fireNow { continuation.resume() }
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = s.now.addingTimeInterval(duration.seconds)
            let (ready, waiting) = s.sleepers.partitioned { $0.wakeAt <= s.now }
            s.sleepers = waiting
            return ready.sorted { $0.wakeAt < $1.wakeAt }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    var pendingSleepers: Int { state.withLock { $0.sleepers.count } }
}

extension Array {
    fileprivate func partitioned(by belongsInFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = [], second: [Element] = []
        for element in self { belongsInFirst(element) ? first.append(element) : second.append(element) }
        return (first, second)
    }
}
