import Foundation
import os

public protocol MediaClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: MediaClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Deterministic time for tests: `sleep` suspends until `advance(by:)` passes the wake time.
public final class TestClock: MediaClock, Sendable {
    private struct Sleeper { let wakeAt: Date; let continuation: CheckedContinuation<Void, any Error> }
    private struct State { var now: Date; var sleepers: [Sleeper] = []; var autoAdvance = false }
    private let state: OSAllocatedUnfairLock<State>

    /// When set, every `sleep` jumps the clock forward instead of waiting for `advance(by:)`.
    public var autoAdvance: Bool {
        get { state.withLock { $0.autoAdvance } }
        set { state.withLock { $0.autoAdvance = newValue } }
    }

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        state = OSAllocatedUnfairLock(initialState: State(now: start))
    }

    public var now: Date { state.withLock { $0.now } }

    public func sleep(for duration: Duration) async throws {
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

    public func advance(by duration: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = s.now.addingTimeInterval(duration.seconds)
            let (ready, waiting) = s.sleepers.partitioned { $0.wakeAt <= s.now }
            s.sleepers = waiting
            return ready.sorted { $0.wakeAt < $1.wakeAt }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    public var pendingSleepers: Int { state.withLock { $0.sleepers.count } }
}

extension Duration {
    public var seconds: TimeInterval {
        let (s, attos) = components
        return TimeInterval(s) + TimeInterval(attos) / 1e18
    }
}

extension Array {
    fileprivate func partitioned(by belongsInFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = [], second: [Element] = []
        for element in self { belongsInFirst(element) ? first.append(element) : second.append(element) }
        return (first, second)
    }
}
