import SwiftUI

public extension View {
    /// Renders whatever `ConfirmCenter` is holding — and tells it that a
    /// surface is on screen to do the rendering.
    ///
    /// That second half matters on macOS: a context menu closes the menu-bar
    /// panel before its item ever fires, and with no host left `ConfirmCenter`
    /// answers with a native alert instead of dropping the action.
    func confirmCenterHost() -> some View { modifier(ConfirmCenterHost()) }
}

private struct ConfirmCenterHost: ViewModifier {
    @ObservedObject private var center = ConfirmCenter.shared

    func body(content: Content) -> some View {
        presented(content)
            .onAppear { center.hasVisibleHost = true }
            .onDisappear { center.hasVisibleHost = false }
    }

    #if os(macOS)
    /// The app's own alert: `.alert` / `.confirmationDialog` don't render
    /// inside a `MenuBarExtra` panel at all.
    private func presented(_ content: Content) -> some View {
        content
            .overlay {
                if let pending = center.pending {
                    ConfirmAlertOverlay(
                        title: LocalizedStringKey(pending.title),
                        message: LocalizedStringKey(pending.message ?? ""),
                        confirmLabelKey: LocalizedStringKey(pending.confirmLabel),
                        cancelLabelKey: LocalizedStringKey(pending.cancelLabel),
                        destructive: pending.isDestructive,
                        onConfirm: { center.confirm() },
                        onCancel: { center.cancel() }
                    )
                }
            }
            .animation(.smooth(duration: 0.18), value: center.pending?.id)
    }
    #else
    /// iOS has a real window and a real alert; use it.
    private func presented(_ content: Content) -> some View {
        content.alert(
            Text(LocalizedStringKey(center.pending?.title ?? ""), bundle: .module),
            isPresented: Binding(
                get: { center.pending != nil },
                set: { if !$0 { center.cancel() } }
            ),
            presenting: center.pending
        ) { pending in
            Button(role: pending.isDestructive ? .destructive : nil) {
                center.confirm()
            } label: {
                Text(LocalizedStringKey(pending.confirmLabel), bundle: .module)
            }
            Button(role: .cancel) { center.cancel() } label: {
                Text(LocalizedStringKey(pending.cancelLabel), bundle: .module)
            }
        } message: { pending in
            Text(LocalizedStringKey(pending.message ?? ""), bundle: .module)
        }
    }
    #endif
}
