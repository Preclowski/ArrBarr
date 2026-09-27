#if os(macOS)
import AppKit
import Foundation

/// Confirmation for actions raised with no ArrBarr surface on screen (a row's context menu has
/// already closed the panel). `NSAlert` is focus-stable, which the panel is not.
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
        // Nothing of ours is in front (the panel just closed), so the alert could open behind another app.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ConfirmCenter.shared.confirm(suppressing: alert.suppressionButton?.state == .on)
        } else {
            ConfirmCenter.shared.cancel()
        }
    }
}
#endif
