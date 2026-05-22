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
    private let invokeTool: @Sendable (_ name: String, _ args: JSONValue) async throws -> String
    private var pendingResume: CheckedContinuation<Bool, Never>?

    public init(provider: LLMProvider,
                tools: [LLMTool],
                invokeTool: @escaping @Sendable (_ name: String, _ args: JSONValue) async throws -> String) {
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

    public func confirmPending() async {
        guard pendingConfirm != nil else { return }
        pendingResume?.resume(returning: true)
        pendingResume = nil
    }

    public func cancelPending() async {
        guard pendingConfirm != nil else { return }
        pendingResume?.resume(returning: false)
        pendingResume = nil
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
                let toolCall = response.toolCalls.first  // v1: handle one call per round.
                let assistantMsg = ChatMessage(role: .assistant, content: response.text, toolCall: toolCall)
                messages.append(assistantMsg)
                guard let call = toolCall else { return }

                if MCPToolWhitelist.isDestructive(call.name) {
                    isThinking = false
                    pendingConfirm = call
                    let proceed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        self.pendingResume = cont
                    }
                    pendingConfirm = nil
                    isThinking = true
                    if !proceed {
                        messages.append(ChatMessage(role: .tool, content: call.name, toolResult: "(cancelled by user)"))
                        nextPrompt = "Tool \(call.name) was cancelled by the user."
                        continue
                    }
                }

                let result: String
                do {
                    result = try await invokeTool(call.name, call.arguments)
                } catch {
                    result = "(tool error: \(error.localizedDescription))"
                }
                messages.append(ChatMessage(role: .tool, content: call.name, toolResult: result))
                nextPrompt = "Tool \(call.name) returned: \(result)"
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
