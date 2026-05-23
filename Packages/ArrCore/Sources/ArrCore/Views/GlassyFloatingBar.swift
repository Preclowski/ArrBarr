import SwiftUI

/// Floating "Liquid Glass" pill chrome used by the chat input bar and the
/// search query field — both want the same Apple-26 feel: rounded capsule,
/// translucent material, soft shadow, sits over the content rather than
/// inside its own structural row.
///
/// On macOS 26+ uses the system `.glassEffect(_:in:)` modifier. On earlier
/// versions falls back to `.regularMaterial` inside a capsule, which gives
/// the same general look without the dynamic refraction.
public extension View {
    func glassyFloatingBar() -> some View {
        modifier(GlassyFloatingBarModifier())
    }

    /// Compact glass pill for inline clusters (row action buttons etc).
    /// Same Liquid Glass / material chrome as `glassyFloatingBar` but
    /// without the drop shadow — meant to live inside another rectangle
    /// (the row's hover-action overlay) where a shadow would muddy the
    /// edge against the fade gradient.
    func glassPill() -> some View {
        modifier(GlassPillModifier())
    }
}

/// Floating glass back button — same Liquid Glass capsule treatment as
/// the tab bar / chat input. Used at the top-left of DetailView,
/// HistoryView, SearchAddPanel and the search overlay so the navigation
/// affordance is visually consistent with the rest of the floating
/// chrome.
public struct FloatingBackButton: View {
    let action: () -> Void
    @State private var isHovering = false

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovering ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassyFloatingBar()
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }
}

private struct GlassPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        #else
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        #endif
    }
}

private struct GlassyFloatingBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        // Stroke overlay is applied on *both* paths — macOS 26 + fallback.
        // Without it, `.glassEffect(.regular, in: .capsule)` on small
        // content (single text label, three dots) renders so subtly that
        // the capsule outline disappears into the popover's vibrancy.
        // Wide pills (tabs cluster) read fine because internal contrast
        // suggests the shape; narrow pills (Add, kebab) need an explicit
        // rim to read as "this is a pill, same as the one next to it".
        let rim = Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5)

        #if os(macOS)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .capsule)
                .overlay(rim)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(rim)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        }
        #else
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .capsule)
                .overlay(rim)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(rim)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        }
        #endif
    }
}
