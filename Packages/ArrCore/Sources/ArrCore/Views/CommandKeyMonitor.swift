import SwiftUI

#if os(macOS)
import AppKit

/// Tracks whether ⌘ is currently held, so surfaces that own a ⌘-number shortcut
/// can reveal it while the key is down (the Safari / Finder idiom of "hold ⌘ to
/// see what the numbers do").
///
/// A *local* monitor is enough: the shortcuts it advertises only fire while the
/// panel is key, and a global monitor would need Accessibility permission for
/// something that must never be worth a prompt. The monitor is installed on
/// `start()` and torn down on `stop()` — the popover appears and disappears
/// constantly, and a leaked monitor keeps firing for the app's lifetime.
@MainActor
@Observable
final class CommandKeyMonitor {
    private(set) var isHeld = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            // MainActor-isolated state from a monitor callback that AppKit
            // already delivers on the main thread.
            MainActor.assumeIsolated {
                self?.isHeld = event.modifierFlags.contains(.command)
            }
            return event
        }
        // ⌘-tab / ⌘-q and friends steal the key-up, so the flag can get stuck
        // "down" when the app loses focus mid-chord. Resigning active always
        // clears it.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isHeld = false }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        isHeld = false
    }
}
#endif
