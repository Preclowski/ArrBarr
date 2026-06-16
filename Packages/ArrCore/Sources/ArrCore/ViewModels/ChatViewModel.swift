import Foundation
import Observation

@MainActor
@Observable
public final class ChatViewModel {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var isThinking: Bool = false
    public private(set) var pendingConfirm: ToolCall?
    public private(set) var lastError: String?

    private let provider: LLMProvider
    private let tools: [LLMTool]
    private let invokeTool: @Sendable (_ name: String, _ args: JSONValue) async throws -> ToolCallOutput
    /// Suspended continuation that resumes when the user taps Confirm
    /// or Cancel on a `ConfirmActionCard`. nil when no destructive
    /// tool is pending. Resume value is `JSONValue?`: confirmed args
    /// to proceed, or nil = cancel.
    private var pendingResume: CheckedContinuation<JSONValue?, Never>?

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

    /// Wipe the conversation. Refuses while a destructive-tool gate is
    /// pending so we don't leak a CheckedContinuation.
    public func clear() {
        guard pendingResume == nil else { return }
        messages = []
        lastError = nil
    }

    /// User tapped Confirm on a ConfirmActionCard. Resumes the
    /// suspended tool with the original args (unchanged — we don't
    /// support arg editing yet, that's a separate UX project).
    public func confirmPending() {
        guard let call = pendingConfirm else { return }
        pendingResume?.resume(returning: call.arguments)
        pendingResume = nil
    }

    /// User tapped Cancel on a ConfirmActionCard. Resumes with nil so
    /// the call-site knows to short-circuit + emit a "cancelled" tool
    /// result.
    public func cancelPending() {
        guard pendingConfirm != nil else { return }
        pendingResume?.resume(returning: nil)
        pendingResume = nil
    }

    /// Block until the user resolves a destructive tool gate. Surfaces
    /// `call` via `pendingConfirm` (the view shows ConfirmActionCard),
    /// suspends until `confirmPending` / `cancelPending` lands, returns
    /// args-to-proceed-with or nil for cancel. Used by both providers:
    ///   - OpenAI path: ChatViewModel.runLoop calls this before
    ///     invoking the tool
    ///   - Foundation Models path: DynamicMCPTool.call calls this via
    ///     the `confirmDestructive` closure wired in ChatViewModelFactory
    /// Re-entrant attempts return nil immediately (one gate at a time).
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
                let toolCalls = response.toolCalls
                guard !toolCalls.isEmpty else {
                    messages.append(ChatMessage(role: .assistant, content: response.text))
                    return
                }

                // The model can return SEVERAL tool calls in one turn
                // (parallel tool-calling). Execute all of them — dropping the
                // extras leaves the next request with tool_calls that were
                // never answered and confuses strict providers. Each call gets
                // its own assistant carrier so every tool result has a matching
                // preceding tool_call in the OpenAI history; the prose rides on
                // the first carrier only.
                var resultSummaries: [String] = []
                for (index, call) in toolCalls.enumerated() {
                    messages.append(ChatMessage(
                        role: .assistant,
                        content: index == 0 ? response.text : "",
                        toolCall: call
                    ))

                    // Destructive-tool gate. For tools that queue indexer
                    // traffic / change arr state (`_search_*`, `_monitor_*`,
                    // `_add_*`, `_delete_*`), pause and surface a confirm
                    // card. Cancel returns "(cancelled by user)" so the
                    // model can adapt its plan.
                    var confirmedArgs = call.arguments
                    if MCPToolWhitelist.isDestructive(call.name) {
                        guard let args = await awaitConfirm(call) else {
                            messages.append(ChatMessage(
                                role: .tool,
                                content: call.name,
                                toolCall: call,
                                toolResult: "(cancelled by user)"
                            ))
                            resultSummaries.append("Tool \(call.name) was cancelled by the user.")
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
                    resultSummaries.append("Tool \(call.name) returned: \(output.text)")
                }
                nextPrompt = resultSummaries.joined(separator: "\n")
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
