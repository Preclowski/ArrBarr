import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The `MenuBarExtra(style: .window)` panel doesn't become key, so modals raised in it ignore
/// clicks. Call `bringForward()` just before presenting one.
enum PanelActivation {
    static func bringForward() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        #endif
    }
}
