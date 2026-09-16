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
    /// - Parameter focused: when true (an active/focused input), the *glass
    ///   itself* lights up — a little white mixed into the material, edge
    ///   catching more light, pill lifting off the list — instead of the field
    ///   wearing a focus ring. Stays fully translucent throughout, and the lift
    ///   is deliberately gentle: enough to say "this one is live", not enough to
    ///   turn the field into the brightest thing in the popover.
    ///   Defaults false, so non-input callers (toolbar islands) are unchanged.
    /// - Parameter cornerRadius: `nil` (the default) keeps the capsule — right
    ///   for anything whose height never changes. Pass a radius for a field that
    ///   *grows* (the multi-line chat input): a capsule's radius is half its
    ///   height, so a growing capsule keeps inflating its own corners until the
    ///   bar reads as a lozenge/circle. A fixed continuous radius sized to the
    ///   one-line height looks identical at rest and simply gets taller.
    /// - Parameter inverted: tints the glass towards the OPPOSITE appearance
    ///   (light in dark mode, dark in light) so an input reads as something you
    ///   type into rather than as more chrome. A hint, not a flip — the content
    ///   keeps the app's own colours.
    /// - Parameter circular: a real `Circle` instead of a capsule. A capsule
    ///   only looks round when its bounds are square, and the glass pads its
    ///   own bounds — so a square one-glyph island still came out an oval.
    func glassyFloatingBar(focused: Bool = false, cornerRadius: CGFloat? = nil,
                           inverted: Bool = false, circular: Bool = false) -> some View {
        modifier(GlassyFloatingBarModifier(lift: focused ? GlassyFloatingBarModifier.litTint : 0,
                                           cornerRadius: cornerRadius,
                                           inverted: inverted,
                                           circular: circular))
            // Sits *above* the modifier on purpose — this is what drives its
            // `animatableData`; put it inside and there's nothing left to
            // interpolate. Asymmetric on purpose too: lighting up is a response
            // to you (quick, 0.18), going dark is you leaving (unhurried, 0.3,
            // so blur-then-click-elsewhere doesn't strobe).
            .animation(focused ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.3), value: focused)
    }

    /// Translucent *frosted-glass* bar for an active mode indicator (queue
    /// multi-select). Keeps the see-through glass — the rows blur through it —
    /// but makes it read as a floating panel rather than dissolving into the
    /// popover's dark vibrancy (the first glass attempt) or going flat-white and
    /// killing the icons' contrast (the opaque attempt). Three cheap cues do the
    /// "it's clearly floating here" work: a bright glass rim, a soft top sheen,
    /// and a real drop shadow. Foreground stays *light* — see the call site.
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

/// The bar's outline: a capsule by default, a fixed-radius continuous rounded
/// rect when a radius is given. One `InsettableShape` for both so the glass,
/// the `stroke` rim and the `strokeBorder` focus rim can all use it (SwiftUI
/// ships no type-erased *insettable* shape, hence the hand-rolled wrapper).
private struct BarShape: InsettableShape {
    var cornerRadius: CGFloat?
    /// Wins over `cornerRadius`: a true circle, inscribed in (and centred on)
    /// whatever bounds it gets.
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

/// `Animatable` is what actually makes the colour *move*. `.glassEffect`'s tint
/// isn't animatable on its own — hand it a new tint and it cuts straight to it,
/// so the pill used to snap between states no matter what `.animation` said.
/// Conforming the modifier and routing everything through one `lift` scalar
/// means SwiftUI interpolates *that*, re-running `body` per frame with an
/// in-between value, and the glass, rim and shadows all ease together for free.
private struct GlassyFloatingBarModifier: ViewModifier, Animatable {
    @Environment(\.colorScheme) private var scheme

    /// How much white goes *into* the glass on focus, 0 at rest. A gentle
    /// brightening, not a spotlight: the pill sits over a dark, low-contrast
    /// list, so it takes very little white to read as "active" — the earlier
    /// 0.26 lit up hard enough to pull the eye off the content it belongs to.
    var lift: Double

    /// `nil` → capsule. Otherwise a fixed continuous corner radius, so a bar
    /// that grows vertically keeps the corners it had on one line.
    var cornerRadius: CGFloat?

    /// Flip the glass against the app's appearance — see `glassyFloatingBar`.
    var inverted: Bool = false

    /// Circle instead of capsule — see `glassyFloatingBar`.
    var circular: Bool = false

    /// One shape for the glass, the rims and the shadows — they must agree or
    /// the rim floats off the material's edge.
    private var shape: BarShape { BarShape(cornerRadius: cornerRadius, isCircle: circular) }

    var animatableData: Double {
        get { lift }
        set { lift = newValue }
    }

    /// Focused-only decoration, as a 0…1 ramp of `lift` — so a half-animated
    /// pill gets a half-lit rim rather than a rim that pops in at the start.
    private var t: Double { min(1, max(0, lift / GlassyFloatingBarModifier.litTint)) }

    static let litTint: Double = 0.12

    /// How much of the opposite appearance goes into an inverted bar — as
    /// little as can still be seen, so the field stays glass rather than
    /// becoming a slab laid on the popover.
    static let invertTint: Double = 0.08

    func body(content: Content) -> some View {
        decorated(base(content))
    }

    /// The glass capsule backdrop (Liquid Glass).
    ///
    /// Focus brightens the glass through `.tint` rather than by stacking a white
    /// capsule behind the content: a `.background` sits *on top of* the glass
    /// layer, so any wash opaque enough to read as "lit" also paints over the
    /// refraction — the pill stops being glass and goes flat white. `.tint`
    /// mixes the white into the material itself, so what's underneath keeps
    /// showing through.
    ///
    /// The content is deliberately left alone, which is the other reason to keep
    /// the tint low: the TextField's `prompt` is AppKit-drawn and stays light
    /// grey, so the brighter the pill, the closer the placeholder gets to
    /// invisible.
    @ViewBuilder
    private func base(_ content: Content) -> some View {
        content.glassEffect(.regular.tint(tint), in: shape)
    }

    /// One tint slot, two directions: inverted bars go towards the opposite
    /// appearance (focus lifts them further), everything else takes only the
    /// focus white.
    private var tint: Color {
        guard inverted else { return Color.white.opacity(lift) }
        let base = scheme == .dark ? Color.white : Color.black
        return base.opacity(GlassyFloatingBarModifier.invertTint + lift)
    }

    private func decorated<V: View>(_ v: V) -> some View {
        v
            // Base rim applied on *both* paths. Without it `.glassEffect` on
            // small content (single label, three dots) renders so subtly the
            // capsule outline dissolves into the popover vibrancy; narrow pills
            // (Add, kebab) need the explicit edge to read as a pill.
            .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
            // No focus *ring* — the lit glass is the cue. What focus adds here
            // is only the edge catching a bit more light, plus lift: a deeper
            // drop shadow and a whisper of white halo, so the active field
            // floats above the list instead of sitting in it. All three scale
            // with the (now gentler) tint, so the whole focus state stays a hint
            // rather than a highlight. Every focused layer is 0-opacity at rest
            // → non-input callers (toolbar islands, "New chat") are unchanged.
            .overlay(shape.strokeBorder(Color.white.opacity(0.12 * t), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.10 + 0.12 * t), radius: 8 + 3 * t, y: 2 + t)
            .shadow(color: .white.opacity(0.07 * t), radius: 7)
    }
}
