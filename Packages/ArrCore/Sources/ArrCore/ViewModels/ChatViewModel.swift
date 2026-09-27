import Foundation
import Observation
import os
import MediaKit

@Observable
public final class ChatViewModel {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var isThinking: Bool = false
    public private(set) var pendingConfirm: ToolCall?
    public private(set) var lastError: String?

    private let provider: LLMProvider
    private let tools: [LLMTool]
    private let invokeTool: @Sendable (_ name: String, _ args: JSONValue) async throws -> ToolCallOutput
    /// Resumed by Confirm (with the args to proceed) or Cancel (nil).
    private var pendingResume: CheckedContinuation<JSONValue?, Never>?
    private let onToolCallStream: (@Sendable (_ name: String, _ arguments: String) -> Void)?
    private let onTurnEnded: (@Sendable () -> Void)?
    private var turnTask: Task<Void, Never>?

    /// Never logs prompts, replies or tool arguments — they are the user's words. Records turn, provider and outcome.
    private static let log = Logger(category: "Chat")

    public var providerIsAvailable: Bool { provider.isAvailable }

    public init(provider: LLMProvider,
                tools: [LLMTool],
                invokeTool: @escaping @Sendable (_ name: String, _ args: JSONValue) async throws -> ToolCallOutput,
                onToolCallStream: (@Sendable (_ name: String, _ arguments: String) -> Void)? = nil,
                onTurnEnded: (@Sendable () -> Void)? = nil) {
        self.onToolCallStream = onToolCallStream
        self.onTurnEnded = onTurnEnded
        self.provider = provider
        self.tools = tools
        self.invokeTool = invokeTool
    }

    public func send(_ text: String) async {
        guard pendingResume == nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: .user, content: trimmed))
        let task = Task { await runLoop(prompt: trimmed) }
        turnTask = task
        await task.value
        turnTask = nil
        onTurnEnded?()
    }

    /// Ignored while a confirm card is up; that gate resolves through its own buttons.
    public func cancelTurn() {
        guard pendingResume == nil else { return }
        turnTask?.cancel()
    }

    /// Refuses while a confirm gate is pending so the CheckedContinuation isn't leaked.
    public func clear() {
        guard pendingResume == nil else { return }
        messages = []
        lastError = nil
    }

    public func confirmPending() {
        guard let call = pendingConfirm else { return }
        pendingResume?.resume(returning: call.arguments)
        pendingResume = nil
    }

    public func cancelPending() {
        guard pendingConfirm != nil else { return }
        pendingResume?.resume(returning: nil)
        pendingResume = nil
    }

    /// Suspends until the user confirms or cancels; nil = cancel. Used by the OpenAI loop and, via
    /// `confirmDestructive`, by Foundation Models tools. Re-entrant calls return nil (one gate at a time).
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

    private func timedRound(_ body: () async throws -> LLMResponse) async rethrows -> LLMResponse {
        let state = AppSignpost.chat.beginInterval("llm round")
        defer { AppSignpost.chat.endInterval("llm round", state) }
        return try await body()
    }

    private func runLoop(prompt: String) async {
        isThinking = true
        defer { isThinking = false }
        Self.log.notice(
            "turn started via \(String(describing: type(of: self.provider)), privacy: .public), \(self.tools.count, privacy: .public) tools offered"
        )
        // Bound once: reading the stored property inside the round's closure is a main-actor access.
        let observer = onToolCallStream
        do {
            var nextPrompt: String? = prompt
            var roundsLeft = 6
            while let p = nextPrompt, roundsLeft > 0 {
                roundsLeft -= 1
                Self.log.debug("round \(6 - roundsLeft, privacy: .public)/6")
                let response = try await timedRound {
                    try await ToolCallStreamContext.$observer.withValue(observer) {
                        try await provider.respond(prompt: p, tools: tools, history: messages)
                    }
                }
                try Task.checkCancellation()

                // The provider already ran the tools in its session; only render, no further round.
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

                let toolCalls = response.toolCalls
                guard !toolCalls.isEmpty else {
                    messages.append(ChatMessage(role: .assistant, content: response.text))
                    return
                }

                // Execute every parallel tool call: unanswered tool_calls confuse strict providers. Each result gets its own
                // assistant carrier so the OpenAI history pairs them.
                var ranAnyTool = false
                for (index, call) in toolCalls.enumerated() {
                    messages.append(ChatMessage(
                        role: .assistant,
                        content: index == 0 ? response.text : "",
                        toolCall: call
                    ))

                    // The backend refuses unconfirmed tools; the card shows the call in context first. Cancel returns
                    // "(cancelled by user)" so the model can adapt.
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

                    // Usually returns the approval already held; asks again only if the backend gates something this loop didn't.
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
                // No prompt: results are already in `messages` as tool messages. Re-sending them as a user turn made
                // the model answer the tool output instead of the question.
                nextPrompt = ranAnyTool ? "" : nil
            }
            if roundsLeft == 0 {
                Self.log.notice("turn hit the 6-round tool-call cap and stopped")
                lastError = String(localized: "chat.error.roundCap", bundle: .module)
                messages.append(ChatMessage(role: .assistant, content: String(localized: "chat.error.stuckInLoop", bundle: .module)))
            }
        } catch where Task.isCancelled {
            Self.log.notice("turn cancelled by the user")
        } catch {
            // The description is the provider's sanitized message; the underlying error can quote the user's prompt, so `.private`.
            Self.log.error(
                "turn failed: \(error.localizedDescription, privacy: .public) | \(String(reflecting: error), privacy: .private)"
            )
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: String(localized: "chat.error.failed \(error.localizedDescription)", bundle: .module)))
        }
    }
}
