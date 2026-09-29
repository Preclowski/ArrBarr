import os
import Foundation
import FoundationModels
import MediaKit

enum FoundationModelsAvailability {
    /// Ready to answer: eligible hardware, Apple Intelligence on, model downloaded.
    nonisolated static var isSupported: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Eligible hardware. The model may still be downloading or switched off, which is temporary,
    /// so a choice of Apple Intelligence is kept rather than swapped for another provider.
    nonisolated static var isOffered: Bool {
        if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability { return false }
        return true
    }
}

struct FoundationModelsProvider: LLMProvider {
    private static let log = Logger(category: "Chat")

    private let invokeTool: @Sendable (String, JSONValue) async throws -> ToolCallOutput
    /// Uses the same ConfirmActionCard as the OpenAI path; returns args to proceed, or nil to cancel.
    private let confirmDestructive: @Sendable (ToolCall) async -> JSONValue?

    init(
        invokeTool: @escaping @Sendable (String, JSONValue) async throws -> ToolCallOutput,
        confirmDestructive: @escaping @Sendable (ToolCall) async -> JSONValue?
    ) {
        self.invokeTool = invokeTool
        self.confirmDestructive = confirmDestructive
    }

    var isAvailable: Bool { FoundationModelsAvailability.isSupported }

    /// Tool calls already ran inside `DynamicMCPTool.call`; `toolResults` tells `ChatViewModel` to render,
    /// not re-execute.
    func respond(
        prompt: String,
        tools: [ToolDefinition],
        history: [ChatMessage]
    ) async throws -> LLMResponse {
        let toolImpls = tools.map { DynamicMCPTool(spec: $0, invokeTool: invokeTool, confirmDestructive: confirmDestructive) }
        func session(_ history: [ChatMessage]) -> LanguageModelSession {
            LanguageModelSession(tools: toolImpls, transcript: Self.transcript(tools: tools, toolImpls: toolImpls, history: history))
        }
        // A cancelled turn leaves its tool calls behind; they'd render as stale cards on this one.
        _ = await DynamicMCPToolBox.shared.drainResults()

        let result: LanguageModelSession.Response<String>
        do {
            result = try await session(history).respond(to: prompt)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize where !history.isEmpty {
            // Earlier turns are the only part that can give way; the instructions and tools must fit alone.
            Self.log.notice("context window full, retrying without earlier turns")
            _ = await DynamicMCPToolBox.shared.drainResults()
            result = try await session([]).respond(to: prompt)
        }
        let (calls, texts, richs) = await DynamicMCPToolBox.shared.drainResults()
        if calls.isEmpty {
            return LLMResponse(text: result.content)
        }
        let outputs = zip(texts, richs).map { ToolCallOutput(text: $0, rich: $1) }
        return LLMResponse(text: result.content, toolCalls: calls, toolResults: outputs)
    }

    // MARK: - Private

    /// Earlier turns enter as transcript entries: replaying them through `respond(to:)` regenerated every
    /// turn and re-ran its tools.
    nonisolated static func transcript(tools: [ToolDefinition], toolImpls: [DynamicMCPTool], history: [ChatMessage]) -> Transcript {
        func text(_ content: String) -> [Transcript.Segment] { [.text(.init(content: content))] }
        var entries: [Transcript.Entry] = [.instructions(.init(
            segments: text(instructions(tools: tools)),
            toolDefinitions: toolImpls.map { Transcript.ToolDefinition(tool: $0) }
        ))]
        for msg in history.suffix(6) where !msg.content.isEmpty {
            switch msg.role {
            case .user: entries.append(.prompt(.init(segments: text(msg.content))))
            case .assistant where msg.toolCall == nil: entries.append(.response(.init(assetIDs: [], segments: text(msg.content))))
            default: break
            }
        }
        return Transcript(entries: entries)
    }

    nonisolated private static func instructions(tools: [ToolDefinition]) -> String {
        return """
            You are ArrBarr's in-app assistant for \(SystemPromptComposer.arrsClause(tools: tools)) — and a film, TV and music obsessive at heart.
            \(tools.isEmpty ? "" : (LibraryStats.shared.promptBlock() ?? ""))
            \(tools.isEmpty ? "" : (TasteProfileStore.shared.promptBlock() ?? ""))
            \(SystemPromptComposer.persona)
            Match the user's language. (This on-device model's output language is bounded by the system Apple Intelligence setting, so there's no point forcing a specific one here.) Keep media titles exactly as the user wrote them.

            How to call a tool:
            - Build a JSON object per the schema in the tool's description,
              then pass it as the tool's `json` argument
              (e.g. {"query": "Severance"}).
            - Questions about what the user ALREADY HAS never go to the
              *_search tools — those find NEW content to add from
              TVDB/TMDB. Route them like this:
                · you can name the title(s) ("do I have X?", "have I seen
                  any of these?") → check_titles, ONCE, with the whole
                  list. Never one lookup per title, never a library browse
                  first, never a guess.
                · you cannot name them yet and want to explore the shelf
                  by filter, or you need a seriesId / season detail →
                  radarr_get_movies / sonarr_get_series.
              The arrs know what was downloaded; the media server knows
              what was played; check_titles answers both at once.

            Otherwise, answer directly without calling a tool.
            Never invent tool names; call only the tools you were given.

            \(SystemPromptComposer.formattingClause)

            \(SystemPromptComposer.linkingClause)

            \(SystemPromptComposer.triviaClause)
            """
    }
}

// MARK: - DynamicMCPToolBox

actor DynamicMCPToolBox {
    nonisolated static let shared = DynamicMCPToolBox()
    private var pendingCalls: [ToolCall] = []
    private var pendingResults: [String] = []
    private var pendingRich: [ChatRichContent?] = []

    func record(call: ToolCall, result: String, rich: ChatRichContent?) {
        pendingCalls.append(call)
        pendingResults.append(result)
        pendingRich.append(rich)
    }

    func drainResults() -> ([ToolCall], [String], [ChatRichContent?]) {
        defer {
            pendingCalls = []
            pendingResults = []
            pendingRich = []
        }
        return (pendingCalls, pendingResults, pendingRich)
    }
}

// MARK: - DynamicMCPTool

/// `@Generable` arguments must be known at compile time, so every dynamic tool shares one `json` string field.
struct DynamicMCPTool: Tool {

    let spec: ToolDefinition
    let invokeTool: @Sendable (String, JSONValue) async throws -> ToolCallOutput
    let confirmDestructive: @Sendable (ToolCall) async -> JSONValue?

    var name: String { spec.name }
    /// The schema rides in the description: the tool definitions already reach the model, the instructions
    /// needn't repeat them.
    var description: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let schema = (try? String(data: encoder.encode(spec.inputSchema), encoding: .utf8)) ?? "{}"
        return spec.description + "\nArgs (JSON): " + schema
    }

    @Generable
    struct Arguments {
        @Guide(description: "JSON object string with arguments matching the tool's input schema.")
        let json: String
    }

    func call(arguments: Arguments) async throws -> String {
        let argsValue = JSONValue.toolArguments(arguments.json)
        let toolCall = ToolCall(name: spec.name, arguments: argsValue)

        // Presentation half of the destructive-tool gate; the backend refuses to run an unconfirmed tool.
        let preApproved: JSONValue?
        if MCPToolWhitelist.isDestructive(spec.name) {
            guard let args = await confirmDestructive(toolCall) else {
                let result = "(cancelled by user)"
                await DynamicMCPToolBox.shared.record(call: toolCall, result: result, rich: nil)
                return result
            }
            preApproved = args
        } else {
            preApproved = nil
        }
        let confirmedArgs = preApproved ?? argsValue

        let confirmAgain = confirmDestructive
        let confirm: ToolConfirmationHandler = { pending in
            if let preApproved { return .approved(preApproved) }
            guard let args = await confirmAgain(pending) else { return .declined }
            return .approved(args)
        }

        let confirmedCall = ToolCall(id: toolCall.id, name: spec.name, arguments: confirmedArgs)
        let output: ToolCallOutput
        do {
            output = try await ToolConfirmationContext.$handler.withValue(confirm) {
                try await invokeTool(spec.name, confirmedArgs)
            }
        } catch LocalToolError.confirmationDeclined(_) {
            let result = "(cancelled by user)"
            await DynamicMCPToolBox.shared.record(call: confirmedCall, result: result, rich: nil)
            return result
        } catch {
            let errOutput = ToolCallOutput(text: "(tool error: \(error.localizedDescription))")
            await DynamicMCPToolBox.shared.record(call: confirmedCall, result: errOutput.text, rich: nil)
            return errOutput.text
        }
        await DynamicMCPToolBox.shared.record(call: confirmedCall, result: output.text, rich: output.rich)
        return output.text
    }
}
