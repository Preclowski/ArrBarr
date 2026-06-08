import SwiftUI

// MARK: - Font scale environment + modifier
//
// Lets the user globally bump every UI font size via a single Settings
// preset (1.0 / 1.10 / 1.20). The codebase is full of explicit
// `.font(.system(size: N))` calls (282 sites at last count) — SwiftUI's
// native `.dynamicTypeSize(...)` only affects semantic fonts
// (`.body`, `.caption`), not explicit pt sizes, so we route every
// font definition through `scaledFont(size:)` which multiplies by the
// environment-injected scale before handing it to SwiftUI.

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

public extension View {
    /// Injects the user's font-scale preset into the environment so every
    /// `.scaledFont` descendant respects it.
    ///
    /// **Must be applied at the root of every independent scene.** The app's
    /// scenes don't share a SwiftUI ancestor — the menu-bar popover, the main
    /// window and the Settings window are each hosted separately (and iOS has
    /// its own `TabView` root) — so the value can't be injected once globally.
    /// Each scene root self-injects via this modifier; because the hosting
    /// view observes `configStore`, the value re-reads live on every preset
    /// change. Forgetting it on a scene root means every `.scaledFont` there
    /// silently falls back to 1.0 — the bug this centralizes against.
    func appFontScale(_ configStore: ConfigStore) -> some View {
        environment(\.fontScale, configStore.effectiveFontScale)
    }
}

public extension ConfigStore {
    /// SwiftUI color-scheme override for the appearance preset; `nil` follows
    /// the system. Apply via `.preferredColorScheme(_:)` at each scene root.
    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// Drop-in replacement for `.font(.system(size:weight:design:))` that
/// respects the user's `fontScale` preset. Takes the same arguments as
/// `Font.system`, plus an optional `monospacedDigit` flag to mirror the
/// chained `.monospacedDigit()` form some sites use.
///
/// Existing call:        `.font(.system(size: 11, weight: .semibold))`
/// Equivalent scaled:    `.scaledFont(size: 11, weight: .semibold)`
public extension View {
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(ScaledFontModifier(
            size: size,
            weight: weight,
            design: design,
            monospacedDigit: monospacedDigit
        ))
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.fontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        var font = Font.system(size: size * scale, weight: weight, design: design)
        if monospacedDigit { font = font.monospacedDigit() }
        return content.font(font)
    }
}
