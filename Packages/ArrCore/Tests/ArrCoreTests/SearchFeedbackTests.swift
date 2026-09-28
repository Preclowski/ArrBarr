import SwiftUI
import Testing
@testable import ArrCore

@MainActor
struct SearchFeedbackTests {
    private final class Box { var value: SearchFeedback = .idle }
    private struct Refused: LocalizedError { var errorDescription: String? { "refused" } }

    private func settle(_ box: Box, until done: (SearchFeedback) -> Bool) async {
        for _ in 0..<200 where !done(box.value) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("An accepted command reads as queued, a refused one as failed with the reason")
    func outcomes() async {
        let box = Box()
        let binding = Binding(get: { box.value }, set: { box.value = $0 })
        SearchFeedback.run(binding) {}
        #expect(box.value == .sending)
        await settle(box) { $0 != .sending }
        #expect(box.value == .queued)

        let failing = Box()
        SearchFeedback.run(Binding(get: { failing.value }, set: { failing.value = $0 })) { throw Refused() }
        await settle(failing) { $0 != .sending }
        #expect(failing.value == .failed("refused"))
    }

    @Test("A second tap while sending is ignored")
    func oneAtATime() async {
        let box = Box()
        let binding = Binding(get: { box.value }, set: { box.value = $0 })
        var calls = 0
        SearchFeedback.run(binding) { calls += 1; try await Task.sleep(for: .milliseconds(50)) }
        SearchFeedback.run(binding) { calls += 1 }
        await settle(box) { $0 != .sending }
        #expect(calls == 1)
    }
}
