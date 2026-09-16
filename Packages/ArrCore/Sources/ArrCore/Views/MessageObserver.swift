import SwiftUI

public extension View {
    /// Runs `perform` for every `AppMessages` message of `type` while the view is in the hierarchy.
    func onMessage<M: NotificationCenter.AsyncMessage>(_ type: M.Type, perform: @escaping @MainActor (M) -> Void) -> some View where M.Subject == AppMessageBus {
        task {
            for await message in NotificationCenter.default.messages(of: nil as AppMessageBus?, for: type) {
                perform(message)
            }
        }
    }
}
