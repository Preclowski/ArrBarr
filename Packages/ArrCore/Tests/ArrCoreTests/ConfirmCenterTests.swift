import Testing
import Foundation
@testable import ArrCore

@Suite("ConfirmCenter")
@MainActor
struct ConfirmCenterTests {

    /// Every test claims a visible host. Without one, macOS answers the request
    /// with a native alert — `runModal()` would block the test run forever.
    private func center() -> ConfirmCenter {
        let c = ConfirmCenter()
        c.hasVisibleHost = true
        return c
    }

    private func pending(_ onConfirm: @escaping @MainActor () -> Void) -> PendingConfirm {
        PendingConfirm(title: "Cancel this download?",
                       message: "This will remove the download from the client.",
                       confirmLabel: "Cancel download",
                       cancelLabel: "Keep download",
                       isDestructive: true,
                       onConfirm: onConfirm)
    }

    @Test("A request is held until it is answered")
    func requestIsHeldUntilAnswered() {
        // The regression this guards: the confirmation used to be a posted
        // message, so a request raised from a context menu — which has already
        // closed the menu-bar panel — reached no observer and the action was
        // silently dropped. Held as state, it is still there whenever a surface
        // (or the native alert) gets to it.
        let c = center()
        #expect(c.pending == nil)
        c.request(pending {})
        #expect(c.pending?.title == "Cancel this download?")
    }

    @Test("Confirming runs the action exactly once and clears the request")
    func confirmRunsTheActionOnce() {
        let c = center()
        var ran = 0
        c.request(pending { ran += 1 })
        c.confirm()
        #expect(ran == 1)
        #expect(c.pending == nil)
        c.confirm()
        #expect(ran == 1, "a second confirm has nothing left to run")
    }

    @Test("Cancelling drops the request without running the action")
    func cancelDropsTheRequest() {
        let c = center()
        var ran = false
        c.request(pending { ran = true })
        c.cancel()
        #expect(!ran)
        #expect(c.pending == nil)
    }
}
