import SwiftUI

#if os(macOS)
import AppKit

/// SwiftUI's `.popover(isPresented:)` wraps an `NSPopover` whose default
/// `behavior` is `.transient`. Transient popovers close on *any* click
/// outside their content — and that click is consumed by the dismissal,
/// not delivered to whatever the user was actually trying to interact with.
///
/// For hover-revealed informational popovers (queue/group row tooltips)
/// that's the wrong trade: users expect clicking the row to open detail,
/// or clicking a button to fire its action — not "click once to close
/// the floating panel, click again to do the thing".
///
/// `.applicationDefined` makes the popover ignore those outside clicks
/// entirely. The view that owns it has to close it explicitly when the
/// hover state changes (which we already do via `showTooltip = false`
/// in `onHover { ... }`).
///
/// Usage: attach `.popoverBehavior(.applicationDefined)` to the popover's
/// content view. The modifier walks up the AppKit window chain to find
/// the hosting NSPopover and tweaks it after presentation.
public extension View {
    func popoverBehavior(_ behavior: NSPopover.Behavior) -> some View {
        background(PopoverBehaviorAdjuster(behavior: behavior))
    }
}

private struct PopoverBehaviorAdjuster: NSViewRepresentable {
    let behavior: NSPopover.Behavior

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Defer until the view is in a window — at make-time the popover's
        // window hasn't been wired up yet.
        DispatchQueue.main.async {
            Self.popover(hosting: nsView)?.behavior = behavior
        }
    }

    /// SwiftUI's popover hosting window keeps a reference to its
    /// `NSPopover` via the (private) `popover` KVC key. The key has been
    /// stable across macOS releases since the API was introduced; if it
    /// ever changes the lookup silently no-ops and we fall back to the
    /// transient default — no crash.
    private static func popover(hosting view: NSView) -> NSPopover? {
        var window: NSWindow? = view.window
        while let w = window {
            if let popover = w.value(forKey: "popover") as? NSPopover {
                return popover
            }
            window = w.parent
        }
        return nil
    }
}
#endif
