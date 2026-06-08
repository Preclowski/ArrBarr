import SwiftUI

public extension View {
    /// Modal-style confirmation overlay attached to a view. Renders
    /// scrim + `InlineConfirmCard` centered. Used by DetailView /
    /// EpisodeDetailOverlay where the confirmation lives inside the
    /// destination (not at popover root) — for queue rows use
    /// `ConfirmCenter.request(...)` which goes through the panel-level
    /// overlay in `PopoverContentView`.
    func inlineConfirm(
        isPresented: Binding<Bool>,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        confirmLabel: LocalizedStringKey,
        cancelLabel: LocalizedStringKey = "Cancel",
        isDestructive: Bool = false,
        onConfirm: @escaping () -> Void
    ) -> some View {
        overlay {
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
    }
}
