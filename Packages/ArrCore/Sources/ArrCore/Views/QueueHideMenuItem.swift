import SwiftUI

/// "Hide" / "Unhide" for a queue row's context menu. Purely local view state,
/// so unlike the mutating items it stays available offline.
struct QueueHideMenuItem: View {
    let items: [QueueItem]
    private var queueUI: QueueUIState { .shared }

    var body: some View {
        if queueUI.areHidden(items) {
            Button { queueUI.unhide(items) } label: {
                Label { Text("queue.unhide.button", bundle: .module) } icon: { Image(systemName: "eye") }
            }
        } else {
            Button(action: hide) {
                Label { Text("queue.hide.button", bundle: .module) } icon: { Image(systemName: "eye.slash") }
            }
        }
    }

    private func hide() {
        let items = items
        let apply = { withAnimation(.smooth(duration: 0.22)) { QueueUIState.shared.hide(items) } }
        guard !queueUI.hideHintSuppressed else { return apply() }
        #if os(macOS)
        let message = "queue.hideHint.message.macos"
        #else
        let message = "queue.hideHint.message.ios"
        #endif
        ConfirmCenter.request(PendingConfirm(
            title: "queue.hideHint.title",
            message: message,
            confirmLabel: "queue.hide.button",
            suppressionLabel: "queue.hideHint.suppress",
            onConfirm: apply,
            onSuppress: { QueueUIState.shared.hideHintSuppressed = true }
        ))
    }
}
