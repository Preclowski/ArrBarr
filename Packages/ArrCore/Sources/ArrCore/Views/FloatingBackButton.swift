import SwiftUI

/// Apple-native back button — bare chevron, no pill, no fill. Matches
/// what macOS Settings.app and iOS NavigationStack ship: just the
/// glyph in accent / secondary color, hit-target padded but not
/// outlined. Apple's HIG explicitly doesn't put a capsule around nav
/// back; we dropped ours to stop looking handcrafted.
public struct FloatingBackButton: View {
    let action: () -> Void
    @State private var isHovering = false

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                // Generous hit target without a visible pill: tap goes
                // through anywhere in the 28×28 padded area but only
                // the glyph itself paints.
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("settings.back.button", bundle: .module))
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }
}
