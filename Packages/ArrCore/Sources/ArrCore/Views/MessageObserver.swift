import SwiftUI

public extension View {
    /// Held by state rather than a bare `.task`: the panel disappears constantly and
    /// an `AsyncMessage` has no replay, so a restarting task lost posts in the gap.
    func onMessage<M: NotificationCenter.AsyncMessage>(_ type: M.Type, perform: @escaping @MainActor (M) -> Void) -> some View where M.Subject == AppMessageBus {
        modifier(MessageObserver<M>(perform: perform))
    }
}

private struct MessageObserver<M: NotificationCenter.AsyncMessage>: ViewModifier where M.Subject == AppMessageBus {
    let perform: @MainActor (M) -> Void
    @State private var observation = Observation<M>()

    func body(content: Content) -> some View {
        // Re-armed on every update so the handler never closes over a stale
        // view value; both calls are idempotent and change no SwiftUI state.
        observation.perform = perform
        observation.start()
        return content
    }
}

private final class Observation<M: NotificationCenter.AsyncMessage> where M.Subject == AppMessageBus {
    var perform: @MainActor (M) -> Void = { _ in }
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            for await message in NotificationCenter.default.messages(of: nil as AppMessageBus?, for: M.self) {
                self?.perform(message)
            }
        }
    }

    isolated deinit { task?.cancel() }
}
