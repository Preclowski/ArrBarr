import SwiftUI

/// Chat tab body. Renders either `ChatView` when the configured AI
/// provider is reachable or `ChatUnavailableView` when it isn't —
/// `PopoverContentView` already gates whether the Chat tab is visible
/// at all via `chatAvailable`, but we double-check the provider state
/// here because availability can flip mid-session (e.g. OpenAI key
/// becomes invalid).
struct ChatTabContent: View {
    // `@Observable` holder — observation is automatic when `body` reads its
    // properties, so no `@ObservedObject` wrapper is needed.
    var chatHolder: ChatViewModelHolder

    var body: some View {
        if !chatHolder.vm.providerIsAvailable {
            ChatUnavailableView(reason: .providerUnavailable)
        } else {
            ChatView(viewModel: chatHolder.vm)
        }
    }
}
