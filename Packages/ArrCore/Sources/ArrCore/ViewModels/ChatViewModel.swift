import Foundation
import Observation
import os

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

    /// Never logs a prompt, a reply or a tool argument — all three are the
    /// user's own words. What it records is that a turn happened, which
    /// provider handled it (an on-device model and a third-party API are very
    /// different answers to "where did my question go"), and how it ended.
    private static let log = Logger(category: "Chat")

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
        Self.log.notice(
            "turn started via \(String(describing: type(of: self.provider)), privacy: .public), \(self.tools.count, privacy: .public) tools offered"
        )
        do {
            var nextPrompt: String? = prompt
            // Hard cap on rounds to keep a misbehaving model from spinning forever.
            var roundsLeft = 6
            while let p = nextPrompt, roundsLeft > 0 {
                roundsLeft -= 1
                Self.log.debug("round \(6 - roundsLeft, privacy: .public)/6")
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
                var ranAnyTool = false
                for (index, call) in toolCalls.enumerated() {
                    messages.append(ChatMessage(
                        role: .assistant,
                        content: index == 0 ? response.text : "",
                        toolCall: call
                    ))

                    // Destructive-tool gate, presentation half. The backend is
                    // what refuses to RUN an unconfirmed tool (see
                    // LocalToolBackend.callTool); we put the confirm card up
                    // first so the user sees the call in context, then hand
                    // that answer down through ToolConfirmationContext.
                    // Cancel returns "(cancelled by user)" so the model can
                    // adapt its plan.
                    let preApproved: JSONValue?
                    if MCPToolWhitelist.isDestructive(call.name) {
                        guard let args = await awaitConfirm(call) else {
                            messages.append(ChatMessage(
                                role: .tool,
                                content: call.name,
                                toolCall: call,
                                toolResult: "(cancelled by user)"
                            ))
                            ranAnyTool = true
                            continue
                        }
                        preApproved = args
                    } else {
                        preApproved = nil
                    }
                    let confirmedArgs = preApproved ?? call.arguments

                    // What the backend's gate calls. Usually the card above
                    // already ran for this very call, so we hand back the
                    // approval we're holding. It only asks again if the
                    // backend gates something this loop didn't — the
                    // fail-closed direction, and still worth a card.
                    let confirm: ToolConfirmationHandler = { [weak self] pending in
                        if let preApproved { return .approved(preApproved) }
                        guard let self else { return .unavailable }
                        guard let args = await self.awaitConfirm(pending) else { return .declined }
                        return .approved(args)
                    }

                    let output: ToolCallOutput
                    do {
                        output = try await ToolConfirmationContext.$handler.withValue(confirm) {
                            try await invokeTool(call.name, confirmedArgs)
                        }
                    } catch LocalToolError.confirmationDeclined(_) {
                        // Vetoed at the backend gate rather than the card
                        // above — render it identically.
                        messages.append(ChatMessage(
                            role: .tool,
                            content: call.name,
                            toolCall: call,
                            toolResult: "(cancelled by user)"
                        ))
                        ranAnyTool = true
                        continue
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
                    ranAnyTool = true
                }
                // Next round carries NO prompt. Every result is already in
                // `messages` as a properly-roled tool message, which is what the
                // provider sends; re-sending the same text as a user turn told
                // the model the human had just pasted tool output at it, and it
                // answered that instead of the original question — the tool-call
                // spiral. An empty prompt means "continue from what's there".
                nextPrompt = ranAnyTool ? "" : nil
            }
            if roundsLeft == 0 {
                Self.log.notice("turn hit the 6-round tool-call cap and stopped")
                lastError = "Reached the maximum number of tool-call rounds."
                messages.append(ChatMessage(role: .assistant, content: "Sorry — I got stuck in a loop and stopped."))
            }
        } catch {
            // The user sees `error.localizedDescription` in a bubble and
            // nothing else. Keep that half public (it is a provider's own
            // sanitized message) and put the type/underlying detail behind
            // `.private` — an API error can quote the request that carried the
            // user's prompt.
            Self.log.error(
                "turn failed: \(error.localizedDescription, privacy: .public) | \(String(reflecting: error), privacy: .private)"
            )
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: "Sorry — \(error.localizedDescription)"))
        }
    }
}
