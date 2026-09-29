import SwiftUI

/// Bare chevron, no pill: the HIG doesn't put a capsule around nav back.
struct FloatingBackButton: View {
    let action: () -> Void
    @State private var isHovering = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                // The whole 28×28 area takes the tap; only the glyph paints.
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("settings.back.button", bundle: .module))
        .accessibilityLabel(Text("settings.back.button", bundle: .module))
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }
}
