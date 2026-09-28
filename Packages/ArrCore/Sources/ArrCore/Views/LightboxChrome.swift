import SwiftUI

// MARK: - Lightbox chrome

/// Carries its own shadow: the artwork or video behind the glass can be any colour.
struct LightboxCloseButton: View {
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
        // Glass follows the view's bounds, and macOS button styles add horizontal padding, so pin a square
        // frame first or the circle comes out an oval.
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
