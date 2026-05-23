import Foundation
import Combine

@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isThinking: Bool = false
    @Published public private(set) var lastError: String?

    private let provider: LLMProvider
    private let tools: [LLMTool]
    private let invokeTool: @Sendable (_ name: String, _ args: JSONValue) async throws -> ToolCallOutput

    public var providerIsAvailable: Bool { provider.isAvailable }

    public init(provider: LLMProvider,
                tools: [LLMTool],
                invokeTool: @escaping @Sendable (_ name: String, _ args: JSONValue) async throws -> ToolCallOutput) {
        self.provider = provider
        self.tools = tools
        self.invokeTool = invokeTool
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: .user, content: trimmed))
        await runLoop(prompt: trimmed)
    }

    /// Wipe the conversation.
    public func clear() {
        messages = []
        lastError = nil
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
                // No destructive-tool confirmation gate any more: every shipping
                // tool is read-only or surface-only. The user does additions
                // through SearchAddPanel (tapping the surfaced cards). If a
                // destructive tool is ever reintroduced, gate it back here.
                let toolCall = response.toolCalls.first
                let assistantMsg = ChatMessage(role: .assistant, content: response.text, toolCall: toolCall)
                messages.append(assistantMsg)
                guard let call = toolCall else { return }

                let output: ToolCallOutput
                do {
                    output = try await invokeTool(call.name, call.arguments)
                } catch {
                    output = ToolCallOutput(text: "(tool error: \(error.localizedDescription))")
                }
                messages.append(ChatMessage(
                    role: .tool,
                    content: call.name,
                    toolCall: call,
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
