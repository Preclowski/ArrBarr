import Testing
import Foundation
@testable import ArrCore

@MainActor
@Suite("ChatViewModel")
struct ChatViewModelTests {
    final class FakeProvider: LLMProvider {
        var isAvailable: Bool = true
        var scripted: [LLMResponse] = []
        var callCount = 0
        func respond(prompt: String, tools: [LLMTool], history: [ChatMessage]) async throws -> LLMResponse {
            defer { callCount += 1 }
            return scripted.removeFirst()
        }
    }

    /// A fake tool runner — pretends to be MCP.
    final class FakeMCP {
        var responses: [String: String] = [:]
        func call(name: String, arguments: JSONValue) async throws -> String {
            responses[name] ?? "(no response)"
        }
    }

    private func makeVM(provider: FakeProvider, mcp: FakeMCP) -> ChatViewModel {
        ChatViewModel(
            provider: provider,
            tools: [LLMTool(name: "sonarr_search", description: "", inputSchema: .object([:]))],
            invokeTool: { name, args in try await mcp.call(name: name, arguments: args) }
        )
    }

    @Test("plain text response — no tool calls")
    func plainTextRoundTrip() async throws {
        let p = FakeProvider()
        p.scripted = [LLMResponse(text: "Hi!")]
        let vm = makeVM(provider: p, mcp: FakeMCP())
        await vm.send("hello")
        #expect(vm.messages.count == 2)
        #expect(vm.messages[0].role == .user)
        #expect(vm.messages[0].content == "hello")
        #expect(vm.messages[1].role == .assistant)
        #expect(vm.messages[1].content == "Hi!")
        #expect(vm.isThinking == false)
        #expect(vm.pendingConfirm == nil)
    }

    @Test("non-destructive tool call runs without confirm")
    func nonDestructiveLoop() async throws {
        let p = FakeProvider()
        p.scripted = [
            LLMResponse(text: "Looking it up", toolCalls: [
                ToolCall(name: "sonarr_search", arguments: .object(["query": .string("X")]))
            ]),
            LLMResponse(text: "Found 1 series."),
        ]
        let mcp = FakeMCP()
        mcp.responses["sonarr_search"] = "X (2025)"
        let vm = makeVM(provider: p, mcp: mcp)
        await vm.send("find X")
        // user, assistant("Looking it up" + toolCall), tool, assistant("Found 1 series.")
        #expect(vm.messages.count == 4)
        #expect(vm.messages[2].role == .tool)
        #expect(vm.messages[2].toolResult == "X (2025)")
        #expect(vm.messages[3].content == "Found 1 series.")
        #expect(p.callCount == 2)
    }

    @Test("destructive tool stalls until confirmed")
    func destructiveStalls() async throws {
        let p = FakeProvider()
        p.scripted = [
            LLMResponse(text: "About to add", toolCalls: [
                ToolCall(name: "sonarr_add_series", arguments: .object(["title": .string("X")]))
            ]),
            LLMResponse(text: "Added."),
        ]
        let mcp = FakeMCP()
        mcp.responses["sonarr_add_series"] = "OK"
        let vm = makeVM(provider: p, mcp: mcp)

        // Send returns when the loop is suspended on the confirm gate.
        // We launch send() as a Task and wait for pendingConfirm to surface.
        let sendTask = Task { await vm.send("add X") }
        // Spin until pendingConfirm appears (the VM is @MainActor so we yield).
        var spins = 0
        while vm.pendingConfirm == nil && spins < 100 {
            await Task.yield()
            spins += 1
        }
        #expect(vm.pendingConfirm != nil)
        #expect(vm.pendingConfirm?.name == "sonarr_add_series")

        await vm.confirmPending()
        await sendTask.value

        #expect(vm.pendingConfirm == nil)
        let lastTool = vm.messages.last(where: { $0.role == .tool })
        #expect(lastTool?.toolResult == "OK")
        #expect(vm.messages.last?.content == "Added.")
    }

    @Test("destructive tool cancel skips execution")
    func destructiveCancel() async throws {
        let p = FakeProvider()
        p.scripted = [
            LLMResponse(text: "About to add", toolCalls: [
                ToolCall(name: "sonarr_add_series", arguments: .object(["title": .string("X")]))
            ]),
            LLMResponse(text: "OK, skipped."),
        ]
        let mcp = FakeMCP()
        let vm = makeVM(provider: p, mcp: mcp)

        let sendTask = Task { await vm.send("add X") }
        var spins = 0
        while vm.pendingConfirm == nil && spins < 100 {
            await Task.yield()
            spins += 1
        }
        await vm.cancelPending()
        await sendTask.value

        #expect(vm.pendingConfirm == nil)
        let lastTool = vm.messages.last(where: { $0.role == .tool })
        #expect(lastTool?.toolResult == "(cancelled by user)")
        #expect(vm.messages.last?.content == "OK, skipped.")
    }
}
