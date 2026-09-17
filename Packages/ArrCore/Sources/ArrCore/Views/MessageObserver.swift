import SwiftUI

public extension View {
    /// Runs `perform` for every `AppMessages` message of `type` while this view
    /// exists.
    ///
    /// Deliberately NOT a bare `.task { for await … }`: a task is cancelled the
    /// moment the view disappears and only restarts a turn (in practice several
    /// seconds, with the main actor busy) after it comes back. The menu-bar
    /// panel does that constantly while a chat turn runs, and an `AsyncMessage`
    /// has no replay — anything posted into one of those gaps was gone for
    /// good. The observation is held by state instead, so it spans the whole
    /// life of the view and survives every disappear/reappear in between.
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

@MainActor
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
