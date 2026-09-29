import SwiftUI

/// Floating Liquid Glass pill chrome for input fields and toolbar islands.
public extension View {
    /// - Parameter focused: lights the glass itself (tint, rim, lift) instead of a
    ///   focus ring; kept gentle so the field isn't the brightest thing in the popover.
    /// - Parameter cornerRadius: `nil` keeps the capsule. Pass a radius for a field
    ///   that grows, or the capsule's half-height radius balloons into a lozenge.
    /// - Parameter inverted: tints the glass towards the opposite appearance so an
    ///   input reads as something you type into rather than more chrome.
    /// - Parameter circular: a real `Circle`; the glass pads its own bounds, so a
    ///   square capsule still came out an oval.
    func glassyFloatingBar(focused: Bool = false, cornerRadius: CGFloat? = nil,
                           inverted: Bool = false, circular: Bool = false) -> some View {
        modifier(GlassyFloatingBarModifier(lift: focused ? GlassyFloatingBarModifier.litTint : 0,
                                           cornerRadius: cornerRadius,
                                           inverted: inverted,
                                           circular: circular))
            // Above the modifier on purpose: this drives its `animatableData`.
            // Asymmetric so blur-then-click-elsewhere doesn't strobe.
            .animation(focused ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.3), value: focused)
    }

    /// Frosted-glass bar for an active mode indicator (queue multi-select).
    func selectionModeBar() -> some View {
        modifier(SelectionModeBarModifier())
    }

}

private struct SelectionModeBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // System glass lights its own edge, so the only hand-drawn cue
            // left is the shadow — that is what says "floating above the list".
            .glassEffect(.regular.interactive(), in: .capsule)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
    }
}

/// One `InsettableShape` for capsule and rounded rect: SwiftUI ships no
/// type-erased insettable shape.
nonisolated private struct BarShape: InsettableShape {
    var cornerRadius: CGFloat?
    /// Wins over `cornerRadius`.
    var isCircle: Bool = false
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        if isCircle { return Circle().path(in: r) }
        guard let cornerRadius else { return Capsule().path(in: r) }
        return RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> BarShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// `Animatable` because `.glassEffect`'s tint isn't: a new tint cuts straight to
/// it. Interpolating `lift` re-runs `body` per frame so glass, rim and shadow ease.
private struct GlassyFloatingBarModifier: ViewModifier, Animatable {
    @Environment(\.colorScheme) private var scheme

    /// White mixed into the glass on focus, 0 at rest. Little is needed over a
    /// dark list; more pulls the eye off the content.
    var lift: Double

    var cornerRadius: CGFloat?

    var inverted: Bool = false

    var circular: Bool = false

    /// One shape for glass, rims and shadows, or the rim floats off the material's edge.
    private var shape: BarShape { BarShape(cornerRadius: cornerRadius, isCircle: circular) }

    var animatableData: Double {
        get { lift }
        set { lift = newValue }
    }

    /// 0…1 ramp of `lift`, so a half-animated pill gets a half-lit rim.
    private var t: Double { min(1, max(0, lift / GlassyFloatingBarModifier.litTint)) }

    static let litTint: Double = 0.12

    /// As little as can still be seen, so the field stays glass rather than a slab.
    static let invertTint: Double = 0.08

    func body(content: Content) -> some View {
        decorated(base(content))
    }

    /// Focus brightens via `.tint`, not a white `.background`, which would sit on
    /// top of the glass and flatten it. Keep it low: the AppKit-drawn prompt stays light grey.
    @ViewBuilder
    private func base(_ content: Content) -> some View {
        content.glassEffect(.regular.tint(tint), in: shape)
    }

    private var tint: Color {
        guard inverted else { return Color.white.opacity(lift) }
        let base = scheme == .dark ? Color.white : Color.black
        return base.opacity(GlassyFloatingBarModifier.invertTint + lift)
    }

    private func decorated<V: View>(_ v: V) -> some View {
        v
            // Without a rim, glass on small content dissolves into the popover vibrancy.
            .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
            // Focus layers are 0-opacity at rest, so non-input callers are unchanged.
            .overlay(shape.strokeBorder(Color.white.opacity(0.12 * t), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.10 + 0.12 * t), radius: 8 + 3 * t, y: 2 + t)
            .shadow(color: .white.opacity(0.07 * t), radius: 7)
    }
}
