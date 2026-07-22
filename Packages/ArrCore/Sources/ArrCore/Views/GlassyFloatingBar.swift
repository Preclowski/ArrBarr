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
    ///   itself* lights up — white mixed into the material, edge catching more
    ///   light, pill lifting off the list — instead of the field wearing a
    ///   focus ring. Stays fully translucent throughout.
    ///   Defaults false, so non-input callers (toolbar islands) are unchanged.
    func glassyFloatingBar(focused: Bool = false) -> some View {
        modifier(GlassyFloatingBarModifier(lift: focused ? GlassyFloatingBarModifier.litTint : 0))
            // Sits *above* the modifier on purpose — this is what drives its
            // `animatableData`; put it inside and there's nothing left to
            // interpolate. Asymmetric on purpose too: lighting up is a response
            // to you (quick, 0.18), going dark is you leaving (unhurried, 0.3,
            // so blur-then-click-elsewhere doesn't strobe).
            .animation(focused ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.3), value: focused)
    }

    /// Compact glass pill for inline clusters (row action buttons etc).
    /// Same Liquid Glass / material chrome as `glassyFloatingBar` but
    /// without the drop shadow — meant to live inside another rectangle
    /// (the row's hover-action overlay) where a shadow would muddy the
    /// edge against the fade gradient.
    func glassPill() -> some View {
        modifier(GlassPillModifier())
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
            .background {
                Capsule()
                    // `.ultraThinMaterial` = the lightest frost — translucent
                    // glass (rows show through) with a softer, smaller blur than
                    // `.thinMaterial`. The sheen + rim + shadow keep it readable.
                    .fill(.ultraThinMaterial)
                    // Gentle top-down sheen lifts the pill a touch above the
                    // near-black backdrop without turning it opaque-white.
                    .overlay(
                        Capsule().fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), Color.white.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
            }
            // Bright glass edge — this is what actually delineates the shape
            // against a dark list (the earlier 0.10 rim was invisible).
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.42), lineWidth: 0.75))
            // Strong-ish shadow so the translucent pill visibly floats.
            .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
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

/// `Animatable` is what actually makes the colour *move*. `.glassEffect`'s tint
/// isn't animatable on its own — hand it a new tint and it cuts straight to it,
/// so the pill used to snap between states no matter what `.animation` said.
/// Conforming the modifier and routing everything through one `lift` scalar
/// means SwiftUI interpolates *that*, re-running `body` per frame with an
/// in-between value, and the glass, rim and shadows all ease together for free.
private struct GlassyFloatingBarModifier: ViewModifier, Animatable {
    /// How much white goes *into* the glass on focus, 0 at rest. Tuned to be the
    /// brightest the pill can get while white label text still reads on it —
    /// push past ~0.35 and the content has to invert to dark too, which the
    /// placeholder can't follow (see `base`).
    var lift: Double

    var animatableData: Double {
        get { lift }
        set { lift = newValue }
    }

    /// Focused-only decoration, as a 0…1 ramp of `lift` — so a half-animated
    /// pill gets a half-lit rim rather than a rim that pops in at the start.
    private var t: Double { min(1, max(0, lift / GlassyFloatingBarModifier.litTint)) }

    static let litTint: Double = 0.26

    func body(content: Content) -> some View {
        decorated(base(content))
    }

    /// The glass / material capsule backdrop (26+ Liquid Glass, `.regularMaterial`
    /// below).
    ///
    /// Focus brightens the glass through `.tint` rather than by stacking a white
    /// capsule behind the content: a `.background` sits *on top of* the glass
    /// layer, so any wash opaque enough to read as "lit" also paints over the
    /// refraction — the pill stops being glass and goes flat white. `.tint`
    /// mixes the white into the material itself, so what's underneath keeps
    /// showing through.
    ///
    /// The content is deliberately left alone. Flipping it dark for a true
    /// inversion needs an explicit `.foregroundStyle` — forcing
    /// `\.colorScheme` to `.light` does *not* recolor it — and even then the
    /// TextField's `prompt` is AppKit-drawn and stays light grey, i.e. invisible
    /// on a bright pill. So the glass lifts only as far as white text survives.
    @ViewBuilder
    private func base(_ content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(Color.white.opacity(lift)), in: .capsule)
        } else {
            content
                .background(Capsule().fill(Color.white.opacity(lift * 0.7)))
                .background(.regularMaterial, in: Capsule())
        }
        #else
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(Color.white.opacity(lift)), in: .capsule)
        } else {
            content
                .background(Capsule().fill(Color.white.opacity(lift * 0.7)))
                .background(.regularMaterial, in: Capsule())
        }
        #endif
    }

    private func decorated<V: View>(_ v: V) -> some View {
        v
            // Base rim applied on *both* paths. Without it `.glassEffect` on
            // small content (single label, three dots) renders so subtly the
            // capsule outline dissolves into the popover vibrancy; narrow pills
            // (Add, kebab) need the explicit edge to read as a pill.
            .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
            // No focus *ring* — the lit glass is the cue. What focus adds here
            // is only the edge catching a bit more light, plus lift: a deeper
            // drop shadow and a whisper of white halo, so the active field
            // floats above the list instead of sitting in it. Every focused
            // layer is 0-opacity at rest → non-input callers (toolbar islands,
            // "New chat") are unchanged.
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.20 * t), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.10 + 0.16 * t), radius: 8 + 4 * t, y: 2 + t)
            .shadow(color: .white.opacity(0.14 * t), radius: 7)
    }
}
