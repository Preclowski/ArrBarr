import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether the on-device model is actually usable on THIS device — not just a
/// recent-enough OS, but Apple Intelligence supported AND enabled. The Settings
/// AI provider picker hides the Foundation Models option when this is false.
public enum FoundationModelsAvailability {
    public static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }
}

// FoundationModels is available on macOS 26+ and iOS 26+.
// On older SDK hosts this file compiles as a stub that reports unavailability.
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelsProvider: LLMProvider {

    private let invokeTool: @Sendable (String, JSONValue) async throws -> ToolCallOutput
    /// Closure called when a destructive tool needs user confirmation.
    /// ChatViewModelFactory wires this to `ChatViewModel.awaitConfirm`
    /// so the FM path uses the same ConfirmActionCard surface as the
    /// OpenAI path. Return value: args-to-proceed or nil for cancel.
    private let confirmDestructive: @Sendable (ToolCall) async -> JSONValue?

    public init(
        invokeTool: @escaping @Sendable (String, JSONValue) async throws -> ToolCallOutput,
        confirmDestructive: @escaping @Sendable (ToolCall) async -> JSONValue?
    ) {
        self.invokeTool = invokeTool
        self.confirmDestructive = confirmDestructive
    }

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// One round-trip to the on-device LLM.
    ///
    /// The provider executes all tool calls synchronously inside `DynamicMCPTool.call`,
    /// then drains both calls and results from `DynamicMCPToolBox`. The returned
    /// `LLMResponse` carries `toolResults` so `ChatViewModel` knows the calls are
    /// already done and should only render them, not re-execute.
    public func respond(
        prompt: String,
        tools: [LLMTool],
        history: [ChatMessage]
    ) async throws -> LLMResponse {
        let toolImpls = tools.map { DynamicMCPTool(spec: $0, invokeTool: invokeTool, confirmDestructive: confirmDestructive) }
        let instructions = Self.buildInstructions(tools: tools)
        let session = LanguageModelSession(tools: toolImpls, instructions: instructions)

        // Replay the last few user turns so the model has context.
        // We skip assistant messages because replaying them via `respond(to:)`
        // would cause the session to generate spurious replies — we only feed
        // user content for context.
        for msg in history.suffix(6) where msg.role == .user {
            _ = try? await session.respond(to: msg.content)
        }
        // The replay above re-feeds past user turns purely to seed context. If
        // any of them nudges the model into a tool call, those calls land in
        // the shared box too — drain and DISCARD them here so only the real
        // prompt's calls reach the UI. Otherwise stale tool cards re-render on
        // every message.
        _ = await DynamicMCPToolBox.shared.drainResults()

        let result = try await session.respond(to: prompt)
        let (calls, texts, richs) = await DynamicMCPToolBox.shared.drainResults()
        if calls.isEmpty {
            return LLMResponse(text: result.content)
        }
        let outputs = zip(texts, richs).map { ToolCallOutput(text: $0, rich: $1) }
        return LLMResponse(text: result.content, toolCalls: calls, toolResults: outputs)
    }

    // MARK: - Private

    private static func buildInstructions(tools: [LLMTool]) -> Instructions {
        // Foundation Models sees only a single stringified `json` argument on
        // each DynamicMCPTool, so the framework can't expose the real schema
        // to the model. We compensate by spelling each tool's JSON schema out
        // in the system prompt — the model is then expected to produce a JSON
        // payload matching that shape inside the `json` arg.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let toolBlock = tools.map { t -> String in
            let schemaJSON = (try? String(data: encoder.encode(t.inputSchema), encoding: .utf8)) ?? "{}"
            return """
            • Tool: \(t.name)
              Purpose: \(t.description)
              Args (JSON): \(schemaJSON)
            """
        }.joined(separator: "\n\n")

        return Instructions(
            """
            You are ArrBarr's in-app assistant for \(SystemPromptComposer.arrsClause(tools: tools)) — and a film buff at heart.
            You speak concisely but with real passion for film and TV. You run your own homelab on the same *arr stack, so you talk to the user as a fellow self-hoster: when it helps, you share a hard-won tip on quality profiles, custom formats or release groups — never lecturing. Passion shows in your word choice, not your length: keep it short.
            Match the user's language. (This on-device model's output language is bounded by the system Apple Intelligence setting, so there's no point forcing a specific one here.) Keep media titles exactly as the user wrote them.

            Tools you can call. For each tool the `json` argument MUST be a
            JSON-encoded object matching the schema shown:

            \(toolBlock)

            How to call a tool:
            - Build the JSON object per the schema, then pass it as the
              tool's `json` argument (e.g. {"query": "Severance"}).
            - For add-style tools, first run the matching search tool and
              pass the returned tvdbId/tmdbId; don't guess ids.
            - If a search returns multiple matches, ask the user which one
              before calling an add tool.
            - If the user asks about something they already have
              (e.g. "do I have X?", "what's the status of Y?", "find X in
              my library"), use sonarr_get_series / radarr_get_movies, NOT
              the *_search tools. The *_search tools find NEW content to
              add from TVDB/TMDB; the *_get_* tools query the user's
              existing library.

            Otherwise, answer directly without calling a tool.
            Never invent tool names that are not listed above.

            Replies render as GitHub-flavored Markdown, so format for clarity.
            You MAY use:
              • Markdown tables — ideal for comparing a few titles/specs
                side by side (e.g. quality, size, score across releases)
              • bullet or numbered lists
              • inline emphasis: **bold**, *italic*, `code`, [link](url)
              • headings sparingly (## only, for a longer structured answer)
            Avoid emoji. Keep replies short — usually one short paragraph; reach
            for a table or list only when it genuinely helps (comparisons or
            multi-field data), not for one or two items.

            When you talk about a specific film or show you genuinely know
            (never guess, never invent facts), PROACTIVELY offer one short fun
            fact or behind-the-scenes tidbit — don't wait to be asked. Wrap
            ANY words that reveal a plot point (a twist, an ending, a death,
            who did it) in double pipes: ||like this||. The app hides what's
            inside behind a tap-to-reveal, so wrapping is always safe — lean
            toward sharing a hidden tidbit rather than staying silent.
            For a sentence-long spoiler, put it on its OWN line with a blank line
            before AND after, so it renders as a clean blurred block:

              Loved the ending.

              ||Bruce Willis was dead the whole time.||

            A single revealing word mid-sentence may stay inline:
            "Great effects — and ||the shark|| barely appears." Don't pipe
            ordinary, non-spoiler trivia (release year, cast, budget).
            """
        )
    }
}

// MARK: - DynamicMCPToolBox

/// Actor that collects (tool call, result) pairs recorded by `DynamicMCPTool.call(arguments:)`
/// during a single LLM session. ChatViewModel drains it after `respond` returns
/// and renders them as `.tool` messages without re-executing.
@available(macOS 26.0, iOS 26.0, *)
actor DynamicMCPToolBox {
    static let shared = DynamicMCPToolBox()
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

/// A Foundation Models `Tool` that wraps any `LLMTool` spec at runtime.
///
/// Because Foundation Models requires `@Generable` argument structs to be
/// statically known at compile time, all dynamic tools share one argument
/// struct: a single `json` string field. The tool performs the real MCP call
/// synchronously inside `call(arguments:)` and records both call and result
/// in `DynamicMCPToolBox`.
@available(macOS 26.0, iOS 26.0, *)
struct DynamicMCPTool: Tool {

    let spec: LLMTool
    let invokeTool: @Sendable (String, JSONValue) async throws -> ToolCallOutput
    let confirmDestructive: @Sendable (ToolCall) async -> JSONValue?

    var name: String { spec.name }
    var description: String { spec.description }

    @Generable
    struct Arguments {
        /// A JSON-encoded object whose keys match the tool's input schema.
        @Guide(description: "JSON object string with arguments matching the tool's input schema.")
        let json: String
    }

    func call(arguments: Arguments) async throws -> String {
        let argsValue: JSONValue
        if let data = arguments.json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            argsValue = decoded
        } else {
            argsValue = .object([:])
        }
        let toolCall = ToolCall(name: spec.name, arguments: argsValue)

        // Destructive-tool gate, presentation half (mirror of the OpenAI path
        // in ChatViewModel). The backend refuses to RUN an unconfirmed tool;
        // this surfaces the ConfirmActionCard first and then hands the answer
        // down through ToolConfirmationContext, which the backend reads.
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

        // Same shape as ChatViewModel's: hand back the approval we already
        // hold, and fall back to asking when the backend gates something we
        // didn't.
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

#else

// MARK: - Stub (no FoundationModels SDK)

/// Stub used when compiling on a host or SDK that does not include
/// FoundationModels (macOS < 26 SDK). Reports unavailable at runtime.
public struct FoundationModelsProvider: LLMProvider {
    public init(
        invokeTool: @escaping @Sendable (String, JSONValue) async throws -> ToolCallOutput,
        confirmDestructive: @escaping @Sendable (ToolCall) async -> JSONValue?
    ) {}

    public var isAvailable: Bool { false }

    public func respond(
        prompt: String,
        tools: [LLMTool],
        history: [ChatMessage]
    ) async throws -> LLMResponse {
        LLMResponse(
            text: "Apple Intelligence / Foundation Models is not available on this OS version."
        )
    }
}

#endif
