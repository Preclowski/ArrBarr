import SwiftUI

/// Re-checks provider availability here because it can flip mid-session (e.g. an OpenAI key goes invalid).
struct ChatTabContent: View {
    var chatHolder: ChatViewModelHolder

    var body: some View {
        if !chatHolder.vm.providerIsAvailable {
            ChatUnavailableView(reason: .providerUnavailable)
        } else {
            ChatView(viewModel: chatHolder.vm)
        }
    }
}
