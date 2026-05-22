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
    public func reconfigure(mcp: MCPConfig, provider: ChatProvider, openai: OpenAIConfig) {
        let next = Self.signature(mcp: mcp, provider: provider, openai: openai)
        guard next != lastSignature else { return }
        lastSignature = next
        vm = ChatViewModelFactory.make(mcp: mcp, chatProvider: provider, openai: openai)
    }

    static func signature(mcp: MCPConfig, provider: ChatProvider, openai: OpenAIConfig) -> String {
        [
            mcp.baseURL, mcp.bearerToken, "\(mcp.enabled)",
            provider.rawValue,
            openai.baseURL, openai.apiKey, openai.model,
        ].joined(separator: "|")
    }
}
