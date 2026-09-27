import SwiftUI

#if os(macOS)
import AppKit

/// SwiftUI popovers default to `.transient`, whose outside-click dismissal eats
/// the click. Hover tooltips set `.applicationDefined` and close on hover-out.
public extension View {
    func popoverBehavior(_ behavior: NSPopover.Behavior) -> some View {
        background(PopoverBehaviorAdjuster(behavior: behavior))
    }
}
#endif

/// Every tooltip presenter routes through here so none inherits `.transient`.
public extension View {
    func tooltipPopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge = .trailing,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(macOS)
        modifier(TooltipPopover(isPresented: isPresented, arrowEdge: arrowEdge, tooltip: content))
        #else
        // iOS has no hover; SwiftUI would present a sheet, and a tap opens DetailView anyway.
        self
        #endif
    }
}

#if os(macOS)
private struct TooltipPopover<TooltipContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    @ViewBuilder let tooltip: () -> TooltipContent
    /// Gating the binding closes a tooltip already on screen when a modal alert
    /// appears, and blocks any that resolve while suppressed.
    @Environment(\.suppressRowTooltip) private var suppressed

    func body(content: Content) -> some View {
        content
            .popover(isPresented: Binding(get: { isPresented && !suppressed },
                                          set: { isPresented = $0 }),
                     arrowEdge: arrowEdge) {
                tooltip().popoverBehavior(.applicationDefined)
            }
            // Keep the row's own state honest, so hover-out doesn't re-open it.
            .onChange(of: suppressed) { _, now in if now { isPresented = false } }
    }
}
#endif

#if os(macOS)

private struct PopoverBehaviorAdjuster: NSViewRepresentable {
    let behavior: NSPopover.Behavior

    final class Coordinator { var didConfigure = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Configure once: this runs on every queue refresh, and re-dispatching caused
        // the outer menubar popover to flicker when the lookup escaped to a parent window.
        guard !context.coordinator.didConfigure else { return }
        let coord = context.coordinator
        DispatchQueue.main.async {
            guard let popover = Self.popover(hosting: nsView) else { return }
            popover.behavior = behavior
            // Clear the layer background so NSPopover's translucent chrome shows
            // through instead of a lighter `windowBackgroundColor`.
            if let host = popover.contentViewController?.view {
                host.wantsLayer = true
                host.layer?.backgroundColor = .clear
            }
            coord.didConfigure = true
        }
    }

    /// Uses the private `popover` KVC key (no-ops if it changes). Never walks the
    /// `parent` chain: that can reach the menubar popover's window and clobber it.
    private static func popover(hosting view: NSView) -> NSPopover? {
        guard let window = view.window else { return nil }
        return window.value(forKey: "popover") as? NSPopover
    }
}
#endif
