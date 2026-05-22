import Foundation

// FoundationModels is available on macOS 26+ and iOS 26+.
// On older SDK hosts this file compiles as a stub that reports unavailability.
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelsProvider: LLMProvider {

    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// One round-trip to the on-device LLM.
    ///
    /// Strategy for history replay: we replay the last few user messages in a
    /// fresh session so the model has conversational context, then send the
    /// current prompt. Tool calls are captured via `DynamicMCPToolBox` and
    /// drained after the session responds; ChatViewModel handles the actual
    /// MCP execution.
    public func respond(
        prompt: String,
        tools: [LLMTool],
        history: [ChatMessage]
    ) async throws -> LLMResponse {
        let toolImpls = tools.map { DynamicMCPTool(spec: $0) }
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
        let calls = await DynamicMCPToolBox.shared.drainCalls()
        return LLMResponse(text: result.content, toolCalls: calls)
    }

    // MARK: - Private

    private static func buildInstructions(tools: [LLMTool]) -> Instructions {
        let toolList = tools
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")

        return Instructions(
            """
            You are ArrBarr's in-app assistant for Sonarr (TV) and Radarr (movies).
            Reply in English, in a short, friendly tone.
            The user may be Polish — keep media titles exactly as the user wrote them.

            Available tools:
            \(toolList)

            Call a tool when the request needs live server data or an action.
            Otherwise, answer directly without calling a tool.
            Never invent tool names that are not listed above.
            """
        )
    }
}

// MARK: - DynamicMCPToolBox

/// Actor that collects tool calls recorded by `DynamicMCPTool.call(arguments:)`
/// during a single LLM session. ChatViewModel drains it after `respond` returns
/// and performs the actual MCP execution.
@available(macOS 26.0, iOS 26.0, *)
actor DynamicMCPToolBox {
    static let shared = DynamicMCPToolBox()
    private var pending: [ToolCall] = []

    func record(_ call: ToolCall) {
        pending.append(call)
    }

    func drainCalls() -> [ToolCall] {
        defer { pending = [] }
        return pending
    }
}

// MARK: - DynamicMCPTool

/// A Foundation Models `Tool` that wraps any `LLMTool` spec at runtime.
///
/// Because Foundation Models requires `@Generable` argument structs to be
/// statically known at compile time, all dynamic tools share one argument
/// struct: a single `json` string field. ChatViewModel decodes that JSON and
/// routes it to the correct MCP tool.
@available(macOS 26.0, iOS 26.0, *)
struct DynamicMCPTool: Tool {

    let spec: LLMTool

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
        let call = ToolCall(name: spec.name, arguments: argsValue)
        await DynamicMCPToolBox.shared.record(call)
        // Return a sentinel; ChatViewModel will replace this with the real result.
        return "(deferred — ArrBarr will invoke this tool and resume the conversation)"
    }
}

#else

// MARK: - Stub (no FoundationModels SDK)

/// Stub used when compiling on a host or SDK that does not include
/// FoundationModels (macOS < 26 SDK). Reports unavailable at runtime.
public struct FoundationModelsProvider: LLMProvider {
    public init() {}

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
