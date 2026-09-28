import SwiftUI

public extension View {
    /// iOS: native `.confirmationDialog`. macOS: `ConfirmAlertOverlay`, since
    /// `.confirmationDialog`/`.alert` don't render in a `MenuBarExtra` popover.
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
            // The system clears `isPresented` itself once a button fires.
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
                ConfirmAlertOverlay(
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
