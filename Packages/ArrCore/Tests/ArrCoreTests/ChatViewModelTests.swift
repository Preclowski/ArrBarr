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

    /// A provider whose `respond` body is supplied as a closure, invoked on each call.
    /// Used to simulate providers that call back into the VM (e.g., for confirm gates).
    final class ConfirmingFakeProvider: LLMProvider {
        var isAvailable: Bool = true
        let onRespond: @Sendable () async -> LLMResponse
        init(onRespond: @escaping @Sendable () async -> LLMResponse) { self.onRespond = onRespond }
        func respond(prompt: String, tools: [LLMTool], history: [ChatMessage]) async throws -> LLMResponse {
            await onRespond()
        }
    }

    /// A fake tool runner — pretends to be MCP.
    final class FakeMCP {
        var callCount = 0
        var responses: [String: String] = [:]
        func call(name: String, arguments: JSONValue) async throws -> ToolCallOutput {
            callCount += 1
            return ToolCallOutput(text: responses[name] ?? "(no response)")
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

    @Test("provider pre-executed tool results render without re-invoking MCP")
    func nonDestructiveLoop() async throws {
        let p = FakeProvider()
        p.scripted = [
            LLMResponse(
                text: "Found 1 series.",
                toolCalls: [ToolCall(name: "sonarr_search", arguments: .object(["query": .string("X")]))],
                toolResults: [ToolCallOutput(text: "X (2025)")]
            )
        ]
        let mcp = FakeMCP()
        mcp.responses["sonarr_search"] = "SHOULD NOT BE CALLED"
        let vm = makeVM(provider: p, mcp: mcp)
        await vm.send("find X")
        // user, assistant, tool (display only)
        #expect(vm.messages.count == 3)
        #expect(vm.messages[1].role == .assistant)
        #expect(vm.messages[1].content == "Found 1 series.")
        #expect(vm.messages[2].role == .tool)
        #expect(vm.messages[2].toolResult == "X (2025)")
        #expect(p.callCount == 1)
        #expect(mcp.callCount == 0, "MCP must not be called when provider pre-executed")
    }

    @Test("provider pre-executed tool results propagate rich content")
    func preExecutedRichContent() async throws {
        let p = FakeProvider()
        let richPayload = ChatRichContent.searchSeriesResults([])
        p.scripted = [
            LLMResponse(
                text: "Found results.",
                toolCalls: [ToolCall(name: "sonarr_search", arguments: .object(["query": .string("X")]))],
                toolResults: [ToolCallOutput(text: "X (2025)", rich: richPayload)]
            )
        ]
        let vm = makeVM(provider: p, mcp: FakeMCP())
        await vm.send("find X")
        #expect(vm.messages[2].richContent == richPayload)
    }

    @Test("destructive tool gated via awaitConfirm path")
    func destructiveStalls() async throws {
        var vmCapture: ChatViewModel?
        let provider = ConfirmingFakeProvider {
            let confirmedArgs = await vmCapture!.awaitConfirm(
                ToolCall(name: "sonarr_add_series", arguments: .object(["title": .string("X")]))
            )
            if confirmedArgs != nil {
                return LLMResponse(
                    text: "Added.",
                    toolCalls: [ToolCall(name: "sonarr_add_series", arguments: .object(["title": .string("X")]))],
                    toolResults: [ToolCallOutput(text: "OK")]
                )
            } else {
                return LLMResponse(text: "Skipped.", toolCalls: [], toolResults: nil)
            }
        }
        let vm = ChatViewModel(
            provider: provider,
            tools: [],
            invokeTool: { _, _ in ToolCallOutput(text: "") }
        )
        vmCapture = vm

        let task = Task { await vm.send("add X") }
        var spins = 0
        while vm.pendingConfirm == nil && spins < 100 {
            await Task.yield()
            spins += 1
        }
        #expect(vm.pendingConfirm != nil)
        await vm.confirmPending()
        await task.value
        let assistantMsg = vm.messages.last(where: { $0.role == .assistant })
        #expect(assistantMsg?.content == "Added.")
        let toolMsg = vm.messages.last(where: { $0.role == .tool })
        #expect(toolMsg?.toolResult == "OK")
    }

    @Test("destructive cancel skips execution")
    func destructiveCancel() async throws {
        var vmCapture: ChatViewModel?
        let provider = ConfirmingFakeProvider {
            let confirmedArgs = await vmCapture!.awaitConfirm(
                ToolCall(name: "sonarr_add_series", arguments: .object(["title": .string("X")]))
            )
            if confirmedArgs != nil {
                return LLMResponse(text: "Added.", toolCalls: [], toolResults: nil)
            } else {
                return LLMResponse(text: "Skipped.", toolCalls: [], toolResults: nil)
            }
        }
        let vm = ChatViewModel(
            provider: provider,
            tools: [],
            invokeTool: { _, _ in ToolCallOutput(text: "") }
        )
        vmCapture = vm

        let task = Task { await vm.send("add X") }
        var spins = 0
        while vm.pendingConfirm == nil && spins < 100 {
            await Task.yield()
            spins += 1
        }
        await vm.cancelPending()
        await task.value
        #expect(vm.messages.last?.content == "Skipped.")
    }

    @Test("send() while confirm pending is a no-op")
    func sendIgnoredWhilePending() async throws {
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

        let firstSend = Task { await vm.send("add X") }
        var spins = 0
        while vm.pendingConfirm == nil && spins < 100 {
            await Task.yield()
            spins += 1
        }
        #expect(vm.pendingConfirm != nil)
        let messagesBefore = vm.messages.count

        // Re-entry attempt: should be ignored, not crash or queue.
        await vm.send("ignored")
        #expect(vm.messages.count == messagesBefore, "send() must not append while gated")

        await vm.confirmPending()
        await firstSend.value
    }

    @Test("round cap surfaces a stop message after 6 tool rounds")
    func roundCapStops() async throws {
        let p = FakeProvider()
        // 7 scripted responses each requesting the same non-destructive tool (toolResults nil).
        // Only 6 rounds will run, then the cap kicks in and the loop ends with
        // the synthetic stop message.
        for _ in 0..<7 {
            p.scripted.append(
                LLMResponse(text: "calling", toolCalls: [
                    ToolCall(name: "sonarr_search", arguments: .object([:]))
                ])
            )
        }
        let mcp = FakeMCP()
        mcp.responses["sonarr_search"] = "result"
        let vm = makeVM(provider: p, mcp: mcp)
        await vm.send("loop forever")
        #expect(vm.lastError == "Reached the maximum number of tool-call rounds.")
        #expect(vm.messages.last?.role == .assistant)
        #expect(vm.messages.last?.content == "Sorry — I got stuck in a loop and stopped.")
        // user + 6 (assistant+tool) pairs + 1 final synthetic = 14 messages.
        let expectedCount = 1 + 6 * 2 + 1
        #expect(vm.messages.count == expectedCount)
    }
}
