import SwiftUI

public extension View {
    /// Confirmation prompt.
    ///
    /// On **iOS** this is a NATIVE `.confirmationDialog` (system action
    /// sheet) — the platform-correct way to confirm a destructive action.
    /// On **macOS** it stays the bespoke `ModalConfirmOverlay`, because
    /// `.confirmationDialog`/`.alert` do not render inside a `MenuBarExtra`
    /// popover (the window the whole app lives in there).
    ///
    /// Used by DetailView / EpisodeDetailOverlay where the confirmation lives
    /// inside the destination. For queue rows use `ConfirmCenter.request(...)`.
    func inlineConfirm(
        isPresented: Binding<Bool>,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        confirmLabel: LocalizedStringKey,
        cancelLabel: LocalizedStringKey = "Cancel",
        isDestructive: Bool = false,
        onConfirm: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        return confirmationDialog(
            Text(title, bundle: .module),
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            // The system dismisses the sheet and clears `isPresented` itself
            // once a button fires, so we only run the action.
            Button(role: isDestructive ? .destructive : nil) {
                onConfirm()
            } label: {
                Text(confirmLabel, bundle: .module)
            }
            Button(role: .cancel) { } label: {
                Text(cancelLabel, bundle: .module)
            }
        } message: {
            Text(message, bundle: .module)
        }
        #else
        return overlay {
            if isPresented.wrappedValue {
                ModalConfirmOverlay(
                    title: title,
                    message: message,
                    confirmLabelKey: confirmLabel,
                    cancelLabelKey: cancelLabel,
                    destructive: isDestructive,
                    onConfirm: {
                        isPresented.wrappedValue = false
                        onConfirm()
                    },
                    onCancel: { isPresented.wrappedValue = false }
                )
            }
        }
        #endif
    }
}
