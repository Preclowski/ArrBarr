import SwiftUI

// MARK: - Lightbox chrome
//
// Shared by every full-surface overlay: the poster lightbox and the trailer
// player. Both dim the popover and put one round dismiss control in the corner,
// so the control itself lives here rather than being reimplemented (and drifting
// in size, padding and shortcut) once per surface.

/// Round glass ✕ for a full-surface overlay. Carries the Esc shortcut on macOS,
/// and its own shadow — artwork or video behind the glass can be any colour, so
/// the pill can't rely on contrast from what it sits on.
struct LightboxCloseButton: View {
    /// String-catalog key for the tooltip / accessibility label. Differs per
    /// surface ("Close poster" vs "Close trailer"), which is the only thing
    /// that does.
    let labelKey: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .scaledFont(size: 12, weight: .semibold)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // The glass shape follows the view's BOUNDS, so the bounds have to be
        // square or a "circle" comes out an oval: the button's own style adds
        // horizontal padding around the label on macOS, which is what widened
        // it. Pin the frame first, then draw the glass in it.
        .frame(width: 30, height: 30)
        .glassEffect(.regular.interactive(), in: .circle)
        #if os(macOS)
        .keyboardShortcut(.cancelAction)
        #endif
        .help(Text(LocalizedStringKey(labelKey), bundle: .module))
        .accessibilityLabel(Text(LocalizedStringKey(labelKey), bundle: .module))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        .padding(12)
    }
}
