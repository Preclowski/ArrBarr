import Foundation

@MainActor
public enum ChatViewModelFactory {
    public static func makePlaceholder() -> ChatViewModel {
        ChatViewModel(
            provider: UnavailableLLMProvider(),
            tools: [],
            invokeTool: { _, _ in "" }
        )
    }

    /// Build a fully-wired chat view-model. Caller is responsible for
    /// re-creating it (via `.id(...)`) when MCP config changes.
    public static func make(config: MCPConfig) -> ChatViewModel {
        guard config.isConfigured else { return makePlaceholder() }
        let client = MCPClient(config: config)
        let mcpTools = MCPToolWhitelist.v1Allowed.sorted().map { name in
            LLMTool(name: name, description: "MCP tool: \(name)", inputSchema: .object([:]))
        }

        let invoke: @Sendable (String, JSONValue) async throws -> String = { name, args in
            let result = try await client.callTool(name: name, arguments: args)
            return result.content.compactMap(\.text).joined(separator: "\n")
        }

        // The ChatViewModel hosts the destructive-confirm state. We pass a closure
        // that surfaces it via awaitConfirm. Use weak capture to avoid a retain cycle.
        var vmRef: ChatViewModel? = nil
        let confirm: @Sendable (ToolCall) async -> Bool = { [weak vmRef] call in
            guard let vm = vmRef else { return false }
            return await vm.awaitConfirm(call)
        }

        let provider: LLMProvider
        if #available(macOS 26.0, iOS 26.0, *) {
            provider = FoundationModelsProvider(invokeTool: invoke, confirmDestructive: confirm)
        } else {
            provider = UnavailableLLMProvider()
        }

        let vm = ChatViewModel(
            provider: provider,
            tools: mcpTools,
            invokeTool: invoke
        )
        vmRef = vm
        return vm
    }
}
