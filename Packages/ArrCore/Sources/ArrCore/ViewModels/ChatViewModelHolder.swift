import Foundation
import Combine

/// Hosts the chat view-model at a scope above the tab bar so the conversation
/// survives Queue ↔ Upcoming ↔ Chat switches. SwiftUI's `@StateObject` can't be
/// reassigned, so we wrap the VM in a holder that rebuilds it when the AI/MCP
/// configuration actually changes.
@MainActor
public final class ChatViewModelHolder: ObservableObject {
    @Published public private(set) var vm: ChatViewModel
    private var lastSignature: String = ""

    public init() {
        self.vm = ChatViewModelFactory.makePlaceholder()
    }

    /// Rebuild the underlying VM if (and only if) the relevant config bits changed.
    /// No-op when the signature matches the last build — preserves message history.
    public func reconfigure(store: ConfigStore) {
        let next = Self.signature(store: store)
        guard next != lastSignature else { return }
        lastSignature = next
        vm = ChatViewModelFactory.make(
            toolSource: store.toolSource,
            mcp: store.mcp,
            sonarr: store.sonarr,
            radarr: store.radarr,
            chatProvider: store.chatProvider,
            openai: store.openai
        )
    }

    public static func signature(store: ConfigStore) -> String {
        [
            store.toolSource.rawValue,
            store.mcp.baseURL, store.mcp.bearerToken, "\(store.mcp.enabled)",
            store.sonarr.baseURL, store.sonarr.apiKey, "\(store.sonarr.enabled)",
            store.radarr.baseURL, store.radarr.apiKey, "\(store.radarr.enabled)",
            store.chatProvider.rawValue,
            store.openai.baseURL, store.openai.apiKey, store.openai.model,
        ].joined(separator: "|")
    }
}
