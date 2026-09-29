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
        let transcript = FoundationModelsProvider.transcript(tools: tools, toolImpls: impls, history: [])
        let model = SystemLanguageModel.default
        let used = try await model.tokenCount(for: transcript)
        print("FM budget: \(used) of \(model.contextSize)")
        #expect(used < model.contextSize / 2)
    }
}
