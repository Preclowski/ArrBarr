import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Workaround for a `MenuBarExtra(style: .window)` quirk on macOS:
/// the hosting NSPanel doesn't become key when it appears, so any
/// SwiftUI `.confirmationDialog` / `.alert` / `.sheet` raised from
/// inside it renders but ignores clicks — events pass through to
/// whichever window is behind the menu bar panel (often the desktop).
///
/// Calling `PanelActivation.bringForward()` *just before* flipping
/// the `isPresented` state of the modal forces the app to activate
/// and the panel to become key, so the system actually routes mouse
/// events to the dialog. NSPopover doesn't need this — its host
/// activates automatically.
public enum PanelActivation {
    public static func bringForward() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        #endif
    }
}
