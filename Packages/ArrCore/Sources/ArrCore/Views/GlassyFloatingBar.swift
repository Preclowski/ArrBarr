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

    /// Experimental liquid-glass CTA pill — same chrome shape as the
    /// chat input bar (`glassyFloatingBar`) but with a tint-colored
    /// glow and an inline progress fill, intended for the sticky
    /// "Pause download" / "Resume download" verb. Replaces the
    /// `GlassProminentButtonStyle + progressFillCTA` stack with one
    /// modifier that owns the whole look.
    func liquidGlassProgressCTA(progress: Double, tint: Color) -> some View {
        modifier(LiquidGlassProgressCTAModifier(progress: progress, tint: tint))
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

private struct LiquidGlassProgressCTAModifier: ViewModifier {
    let progress: Double
    let tint: Color
    @State private var hovering = false

    func body(content: Content) -> some View {
        let clamped = max(0, min(1, progress))
        // Progress slab — Rectangle for sharp vertical edge; outer
        // capsule clips the leading round.
        let progressFill = GeometryReader { proxy in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(tint.opacity(0.62))
                    .frame(width: proxy.size.width * clamped)
                Color.clear
            }
        }
        // Bare content — white text on top of the tinted progress
        // slab. NO synthetic gloss / rim gradient (those scream Aqua);
        // a single hairline glass border is added below.
        let baseContent = content
            .foregroundStyle(.white)
            .background(progressFill)
            .clipShape(Capsule())
        // Hairline glass border — barely-there bright stroke that just
        // outlines the capsule edge. Same role the system glass plays
        // when it sits over busy content (Notification Center pills,
        // Music mini-player chrome).
        let glassEdge = Capsule()
            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)

        Group {
            #if os(macOS)
            if #available(macOS 26.0, *) {
                // System Liquid Glass — real refraction + automatic rim.
                // Tint lowered so the unfilled trailing portion reads as
                // transparent glass over the popover content rather than a
                // dim flat slab.
                baseContent
                    .glassEffect(.regular.tint(tint.opacity(hovering ? 0.26 : 0.16)), in: .capsule)
                    .overlay(glassEdge)
                    .shadow(color: .black.opacity(0.20), radius: 6, y: 2)
            } else {
                // Pre-26 fallback — single ultraThinMaterial, very light
                // tint base. We can't fake refraction.
                baseContent
                    .background(tint.opacity(hovering ? 0.22 : 0.13), in: Capsule())
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(glassEdge)
                    .shadow(color: .black.opacity(0.20), radius: 6, y: 2)
            }
            #else
            if #available(iOS 26.0, *) {
                baseContent
                    .glassEffect(.regular.tint(tint.opacity(0.16)), in: .capsule)
                    .overlay(glassEdge)
                    .shadow(color: .black.opacity(0.20), radius: 6, y: 2)
            } else {
                baseContent
                    .background(tint.opacity(0.13), in: Capsule())
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(glassEdge)
                    .shadow(color: .black.opacity(0.20), radius: 6, y: 2)
            }
            #endif
        }
        // Hover affordance for the macOS detail CTAs (Resume/Pause download +
        // trash) — these glass buttons previously had no hover state at all:
        // stronger tint + a hair brighter + a touch larger.
        .brightness(hovering ? 0.06 : 0)
        .scaleEffect(hovering ? 1.015 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
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
