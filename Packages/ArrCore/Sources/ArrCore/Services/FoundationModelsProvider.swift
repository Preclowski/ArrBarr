import Foundation

// FoundationModels is available on macOS 26+ and iOS 26+.
// On older SDK hosts this file compiles as a stub that reports unavailability.
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelsProvider: LLMProvider {

    private let invokeTool: @Sendable (String, JSONValue) async throws -> ToolCallOutput
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
            You are ArrBarr's in-app assistant for Sonarr (TV) and Radarr (movies).
            Reply in English, in a short, friendly tone.
            The user may write in Polish — keep media titles exactly as the user wrote them.

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

        var confirmedArgs = argsValue
        if MCPToolWhitelist.isDestructive(spec.name) {
            guard let args = await confirmDestructive(toolCall) else {
                let result = "(cancelled by user)"
                await DynamicMCPToolBox.shared.record(call: toolCall, result: result, rich: nil)
                return result
            }
            confirmedArgs = args
        }

        let confirmedCall = ToolCall(id: toolCall.id, name: spec.name, arguments: confirmedArgs)
        let output: ToolCallOutput
        do {
            output = try await invokeTool(spec.name, confirmedArgs)
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
