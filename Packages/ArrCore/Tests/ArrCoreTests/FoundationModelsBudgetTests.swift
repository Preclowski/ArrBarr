import Testing
import FoundationModels
@testable import ArrCore

struct FoundationModelsBudgetTests {
    /// The on-device context is small; the opening transcript must leave room for the conversation.
    @available(macOS 26.4, iOS 26.4, *)
    @Test(.enabled(if: FoundationModelsAvailability.isSupported))
    func openingTranscriptFitsTheContext() async throws {
        let tools = ChatToolCatalog.tools(includeLidarr: true, includeTMDBMovies: true, includeTMDBSeries: true, includeMediaServer: true)
        let impls = tools.map { DynamicMCPTool(spec: $0, invokeTool: { _, _ in ToolCallOutput(text: "") }, confirmDestructive: { _ in nil }) }
        let transcript = FoundationModelsProvider.transcript(tools: tools, toolImpls: impls, history: [], replyLanguage: "Polish")
        let model = SystemLanguageModel.default
        let used = try await model.tokenCount(for: transcript)
        print("FM budget: \(used) of \(model.contextSize)")
        #expect(used < model.contextSize / 2)
    }

    /// A tool turn's answer rides on a message carrying `toolCall`, and its tool rows used to fill the window.
    @available(macOS 26.4, iOS 26.4, *)
    @Test func transcriptKeepsAnswersOfToolTurns() {
        let call = ToolCall(name: "list_download_queue", arguments: .object([:]))
        var history = [
            ChatMessage(role: .user, content: "co się ściąga?"),
            ChatMessage(role: .assistant, content: "Trzy pobierania: Dune, Severance, Arrival.", toolCall: call),
        ]
        for _ in 0..<6 { history.append(ChatMessage(role: .tool, content: call.name, toolCall: call, toolResult: "…")) }

        let transcript = FoundationModelsProvider.transcript(tools: [], toolImpls: [], history: history, replyLanguage: "Polish")
        var prompts = 0, responses = 0
        for entry in transcript {
            switch entry {
            case .prompt: prompts += 1
            case .response: responses += 1
            default: break
            }
        }
        #expect(prompts == 1)
        #expect(responses == 1)
    }
}
