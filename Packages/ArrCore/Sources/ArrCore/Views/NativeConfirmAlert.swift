#if os(macOS)
import AppKit
import Foundation

/// The confirmation for actions raised while no ArrBarr surface is on screen —
/// in practice everything started from a row's context menu, because opening
/// that menu already closed the menu-bar panel.
///
/// An `NSAlert` rather than reopening a window: it is focus-stable (the reason
/// the panel cannot host this), it is what a Mac user expects behind a
/// destructive menu item, and it costs no window of our own.
enum NativeConfirmAlert {
    static func present(_ pending: PendingConfirm, locale: Locale) {
        let alert = NSAlert()
        alert.messageText = AppLocalized.string(pending.title, locale: locale)
        if let message = pending.message {
            alert.informativeText = AppLocalized.string(message, locale: locale)
        }
        alert.alertStyle = pending.isDestructive ? .warning : .informational
        let confirmButton = alert.addButton(withTitle: AppLocalized.string(pending.confirmLabel, locale: locale))
        alert.addButton(withTitle: AppLocalized.string(pending.cancelLabel, locale: locale))
        confirmButton.hasDestructiveAction = pending.isDestructive
        if let suppression = pending.suppressionLabel {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = AppLocalized.string(suppression, locale: locale)
        }
        // The app has no window in front at this point (the panel just closed),
        // so without this the alert can open behind whatever the user is in.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ConfirmCenter.shared.confirm(suppressing: alert.suppressionButton?.state == .on)
        } else {
            ConfirmCenter.shared.cancel()
        }
    }
}
#endif
