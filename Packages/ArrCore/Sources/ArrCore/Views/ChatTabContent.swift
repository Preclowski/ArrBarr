import SwiftUI

/// Chat tab body. Renders either `ChatView` when the configured AI
/// provider is reachable or `ChatUnavailableView` when it isn't —
/// `PopoverContentView` already gates whether the Chat tab is visible
/// at all via `chatAvailable`, but we double-check the provider state
/// here because availability can flip mid-session (e.g. OpenAI key
/// becomes invalid).
struct ChatTabContent: View {
    @ObservedObject var chatHolder: ChatViewModelHolder

    var body: some View {
        if !chatHolder.vm.providerIsAvailable {
            ChatUnavailableView(reason: .providerUnavailable)
        } else {
            ChatView(viewModel: chatHolder.vm)
        }
    }
}
