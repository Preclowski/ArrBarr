import os
import Foundation
import FoundationModels
import MediaKit

/// Apple Intelligence supported AND enabled, not just a recent-enough OS.
enum FoundationModelsAvailability {
    nonisolated static var isSupported: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
}

struct FoundationModelsProvider: LLMProvider {

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
        tools: [LLMTool],
        history: [ChatMessage]
    ) async throws -> LLMResponse {
        let toolImpls = tools.map { DynamicMCPTool(spec: $0, invokeTool: invokeTool, confirmDestructive: confirmDestructive) }
        let session = LanguageModelSession(tools: toolImpls, transcript: Self.transcript(tools: tools, toolImpls: toolImpls, history: history))
        // A cancelled turn leaves its tool calls behind; they'd render as stale cards on this one.
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

    /// Earlier turns enter as transcript entries: replaying them through `respond(to:)` regenerated every
    /// turn and re-ran its tools.
    nonisolated private static func transcript(tools: [LLMTool], toolImpls: [DynamicMCPTool], history: [ChatMessage]) -> Transcript {
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

    nonisolated private static func instructions(tools: [LLMTool]) -> String {
        // Foundation Models sees one stringified `json` argument per tool, so each schema is spelled out here.
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

        return """
            You are ArrBarr's in-app assistant for \(SystemPromptComposer.arrsClause(tools: tools)) — and a film, TV and music obsessive at heart.
            \(tools.isEmpty ? "" : (LibraryStats.shared.promptBlock() ?? ""))
            \(tools.isEmpty ? "" : (TasteProfileStore.shared.promptBlock() ?? ""))
            You speak concisely but with real passion for what the user is asking about: a film, a series, a band, an album, a pressing. Music is not a lesser tab — an album gets the same enthusiasm and the same specificity as a film (the producer, the session, the pressing, the run of records around it), and Lidarr is as much your stack as Radarr. You run your own homelab on the same *arr stack, so you talk to the user as a fellow self-hoster: when it helps, you share a hard-won tip on quality profiles, custom formats or release groups — never lecturing. Passion shows in your word choice, not your length: keep it short.
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
            Never invent tool names that are not listed above.

            Replies render as GitHub-flavored Markdown, so format for clarity.
            You MAY use:
              • Markdown tables — ideal for comparing a few titles/specs
                side by side (e.g. quality, size, score across releases)
              • bullet or numbered lists
              • inline emphasis: **bold**, *italic*, `code`
              • in-app links ONLY, in the two forms described below — never a
                web URL
              • headings sparingly (## only, for a longer structured answer)
            Avoid emoji. Keep replies short — usually one short paragraph; reach
            for a table or list only when it genuinely helps (comparisons or
            multi-field data), not for one or two items.

            \(SystemPromptComposer.linkingClause)

            When you talk about a specific film, show, album or artist you genuinely know
            (never guess, never invent facts), PROACTIVELY offer one short fun
            fact or behind-the-scenes tidbit — don't wait to be asked; for a
            record that means the session, the producer, the sample, the split
            that came after it. Wrap
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

    let spec: LLMTool
    let invokeTool: @Sendable (String, JSONValue) async throws -> ToolCallOutput
    let confirmDestructive: @Sendable (ToolCall) async -> JSONValue?

    var name: String { spec.name }
    var description: String { spec.description }

    @Generable
    struct Arguments {
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
