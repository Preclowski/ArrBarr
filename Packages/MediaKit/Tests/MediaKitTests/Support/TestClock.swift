import Foundation
import os
@testable import MediaKit

/// Deterministic time for tests: `sleep` suspends until `advance(by:)` passes the wake time.
final class TestClock: MediaClock, Sendable {
    private struct Sleeper { let id: UUID; let wakeAt: Date; let continuation: CheckedContinuation<Void, any Error> }
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

    /// Cancellation ends the sleep at once, as `Task.sleep` does, so a cancelled sleeper is no longer pending.
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let wakeAt = now.addingTimeInterval(duration.seconds)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Start { case now, wait, cancelled }
                let start = state.withLock { s -> Start in
                    if Task.isCancelled { return .cancelled }
                    if s.autoAdvance { s.now = max(s.now, wakeAt); return .now }
                    if wakeAt <= s.now { return .now }
                    s.sleepers.append(Sleeper(id: id, wakeAt: wakeAt, continuation: continuation))
                    return .wait
                }
                switch start {
                case .now: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let cancelled = state.withLock { s -> Sleeper? in
                s.sleepers.firstIndex { $0.id == id }.map { s.sleepers.remove(at: $0) }
            }
            cancelled?.continuation.resume(throwing: CancellationError())
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
