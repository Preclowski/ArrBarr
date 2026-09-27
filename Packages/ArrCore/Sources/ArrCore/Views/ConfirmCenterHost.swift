import SwiftUI

public extension View {
    /// Also registers a host: a macOS context menu closes the panel before its item
    /// fires, and with no host `ConfirmCenter` falls back to a native alert.
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
    /// `.alert` / `.confirmationDialog` don't render inside a `MenuBarExtra` panel.
    private func presented(_ content: Content) -> some View {
        content
            // Without these, rows under the scrim still took clicks and opened their
            // tooltips, which as floating windows came up on top of the alert.
            .allowsHitTesting(center.pending == nil)
            .disabled(center.pending != nil)
            .accessibilityHidden(center.pending != nil)
            .environment(\.suppressRowTooltip, center.pending != nil)
            .overlay {
                if let pending = center.pending {
                    ConfirmAlertOverlay(
                        title: LocalizedStringKey(pending.title),
                        message: LocalizedStringKey(pending.message ?? ""),
                        confirmLabelKey: LocalizedStringKey(pending.confirmLabel),
                        cancelLabelKey: LocalizedStringKey(pending.cancelLabel),
                        destructive: pending.isDestructive,
                        suppressionLabelKey: pending.suppressionLabel.map { LocalizedStringKey($0) },
                        onConfirm: { center.confirm() },
                        onSuppress: pending.onSuppress,
                        onCancel: { center.cancel() }
                    )
                }
            }
            .animation(.smooth(duration: 0.18), value: center.pending?.id)
    }
    #else
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
            // iOS alerts hold no checkbox: "don't show again" is its own answer.
            if let suppression = pending.suppressionLabel {
                Button { center.confirm(suppressing: true) } label: {
                    Text(LocalizedStringKey(suppression), bundle: .module)
                }
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
