import Foundation
import Observation

/// Calls `action` whenever `value` changes from now on, never with the current value: the Observation
/// counterpart of `$property.dropFirst().removeDuplicates()`, optionally debounced. Runs until the returned
/// task is cancelled, so `value` and `action` capture their owner weakly.
@discardableResult
public func observeChanges<T: Equatable & Sendable>(
    of value: @escaping @MainActor @Sendable () -> T,
    debounce: Duration = .zero,
    _ action: @escaping @MainActor @Sendable (T) -> Void
) -> Task<Void, Never> {
    Task { @MainActor in
        var last = value()
        var pending: Task<Void, Never>?
        for await next in Observations(value) {
            guard next != last else { continue }
            last = next
            pending?.cancel()
            guard debounce > .zero else { action(next); continue }
            pending = Task { @MainActor in
                try? await Task.sleep(for: debounce)
                if !Task.isCancelled { action(next) }
            }
        }
    }
}
