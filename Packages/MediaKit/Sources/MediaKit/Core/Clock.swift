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

extension Duration {
    public var seconds: TimeInterval {
        let (s, attos) = components
        return TimeInterval(s) + TimeInterval(attos) / 1e18
    }
}
