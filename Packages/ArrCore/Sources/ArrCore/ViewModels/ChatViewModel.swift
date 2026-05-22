import Foundation
import Combine

@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isThinking: Bool = false
    @Published public private(set) var pendingConfirm: ToolCall?
    @Published public private(set) var lastError: String?

    private let provider: LLMProvider
    private let tools: [LLMTool]
    private let invokeTool: @Sendable (_ name: String, _ args: JSONValue) async throws -> ToolCallOutput
    private(set) var pendingResume: CheckedContinuation<JSONValue?, Never>?

    public var providerIsAvailable: Bool { provider.isAvailable }

    public init(provider: LLMProvider,
                tools: [LLMTool],
                invokeTool: @escaping @Sendable (_ name: String, _ args: JSONValue) async throws -> ToolCallOutput) {
        self.provider = provider
        self.tools = tools
        self.invokeTool = invokeTool
    }

    public func send(_ text: String) async {
        guard pendingResume == nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: .user, content: trimmed))
        await runLoop(prompt: trimmed)
    }

    public func confirmPending(with arguments: JSONValue) async {
        guard pendingConfirm != nil else { return }
        pendingResume?.resume(returning: arguments)
        pendingResume = nil
    }

    public func cancelPending() async {
        guard pendingConfirm != nil else { return }
        pendingResume?.resume(returning: nil)
        pendingResume = nil
    }

    /// Wipe the conversation. Refuses to clear while a tool is pending so we
    /// don't leak a CheckedContinuation.
    public func clear() {
        guard pendingResume == nil else { return }
        messages = []
        lastError = nil
    }

    /// Surfaces the confirm gate to external callers (e.g. injected into
    /// `FoundationModelsProvider` so `DynamicMCPTool` can pause the FM session).
    /// Re-entrant calls return nil immediately. Returns nil for cancel, or the
    /// (possibly user-modified) args JSONValue to proceed with.
    public func awaitConfirm(_ call: ToolCall) async -> JSONValue? {
        guard pendingResume == nil else { return nil }
        pendingConfirm = call
        isThinking = false
        let result = await withCheckedContinuation { (cont: CheckedContinuation<JSONValue?, Never>) in
            self.pendingResume = cont
        }
        pendingConfirm = nil
        isThinking = true
        return result
    }

    private func runLoop(prompt: String) async {
        isThinking = true
        defer { isThinking = false }
        do {
            var nextPrompt: String? = prompt
            // Hard cap on rounds to keep a misbehaving model from spinning forever.
            var roundsLeft = 6
            while let p = nextPrompt, roundsLeft > 0 {
                roundsLeft -= 1
                let response = try await provider.respond(prompt: p, tools: tools, history: messages)

                // --- Pre-executed path (e.g. FoundationModelsProvider) ---
                // The provider already ran the tools inside its session; toolResults is non-nil.
                // We only render the messages — no re-execution, no further round.
                if let toolResults = response.toolResults {
                    let toolCall = response.toolCalls.first
                    let assistantMsg = ChatMessage(role: .assistant, content: response.text, toolCall: toolCall)
                    messages.append(assistantMsg)
                    for (call, output) in zip(response.toolCalls, toolResults) {
                        messages.append(ChatMessage(
                            role: .tool,
                            content: call.name,
                            toolCall: call,
                            toolResult: output.text,
                            richContent: output.rich
                        ))
                    }
                    return
                }

                // --- View-model-executes path (e.g. OpenAI provider) ---
                let toolCall = response.toolCalls.first
                let assistantMsg = ChatMessage(role: .assistant, content: response.text, toolCall: toolCall)
                messages.append(assistantMsg)
                guard let call = toolCall else { return }

                var confirmedArgs = call.arguments
                if MCPToolWhitelist.isDestructive(call.name) {
                    guard let args = await awaitConfirm(call) else {
                        messages.append(ChatMessage(
                            role: .tool,
                            content: call.name,
                            toolCall: call,
                            toolResult: "(cancelled by user)"
                        ))
                        nextPrompt = "Tool \(call.name) was cancelled by the user."
                        continue
                    }
                    confirmedArgs = args
                }

                let output: ToolCallOutput
                do {
                    output = try await invokeTool(call.name, confirmedArgs)
                } catch {
                    output = ToolCallOutput(text: "(tool error: \(error.localizedDescription))")
                }
                let confirmedCall = ToolCall(id: call.id, name: call.name, arguments: confirmedArgs)
                messages.append(ChatMessage(
                    role: .tool,
                    content: call.name,
                    toolCall: confirmedCall,
                    toolResult: output.text,
                    richContent: output.rich
                ))
                nextPrompt = "Tool \(call.name) returned: \(output.text)"
            }
            if roundsLeft == 0 {
                lastError = "Reached the maximum number of tool-call rounds."
                messages.append(ChatMessage(role: .assistant, content: "Sorry — I got stuck in a loop and stopped."))
            }
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: "Sorry — \(error.localizedDescription)"))
        }
    }
}
