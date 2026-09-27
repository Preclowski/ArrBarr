import SwiftUI

#if os(macOS)
import AppKit

/// Local monitor only: a global one needs Accessibility permission. Stopped on
/// popover close, or a leaked monitor fires for the app's lifetime.
@Observable
final class CommandKeyMonitor {
    private(set) var isHeld = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            // AppKit already delivers this on the main thread.
            MainActor.assumeIsolated {
                self?.isHeld = event.modifierFlags.contains(.command)
            }
            return event
        }
        // ⌘-tab / ⌘-q steal the key-up; resigning active clears a stuck flag.
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
